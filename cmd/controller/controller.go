package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sync/atomic"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/util/retry"
)

type controllerConfig struct {
	namespace      string
	configMapName  string
	deploymentName string
	annotationKey  string
	rolloutDelay   time.Duration
}

type rolloutController struct {
	client  kubernetes.Interface
	config  controllerConfig
	logger  *slog.Logger
	ready   atomic.Bool
	trigger chan struct{}
}

func newRolloutController(client kubernetes.Interface, config controllerConfig, logger *slog.Logger) *rolloutController {
	return &rolloutController{
		client:  client,
		config:  config,
		logger:  logger,
		trigger: make(chan struct{}, 1),
	}
}

func (c *rolloutController) enqueue(_ any) {
	select {
	case c.trigger <- struct{}{}:
	default:
	}
}

func (c *rolloutController) run(ctx context.Context) error {
	factory := informers.NewSharedInformerFactoryWithOptions(
		c.client,
		0,
		informers.WithNamespace(c.config.namespace),
		informers.WithTweakListOptions(func(options *metav1.ListOptions) {
			options.FieldSelector = fields.OneTermEqualSelector("metadata.name", c.config.configMapName).String()
		}),
	)
	informer := factory.Core().V1().ConfigMaps().Informer()
	if _, err := informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: c.enqueue,
		UpdateFunc: func(oldObject, newObject any) {
			oldConfigMap, oldOK := oldObject.(*corev1.ConfigMap)
			newConfigMap, newOK := newObject.(*corev1.ConfigMap)
			if oldOK && newOK && oldConfigMap.ResourceVersion == newConfigMap.ResourceVersion {
				return
			}
			c.enqueue(newObject)
		},
	}); err != nil {
		return err
	}

	factory.Start(ctx.Done())
	if !cache.WaitForCacheSync(ctx.Done(), informer.HasSynced) {
		if ctx.Err() != nil {
			return nil
		}
		return errors.New("ConfigMap informer cache did not sync")
	}
	c.ready.Store(true)
	defer c.ready.Store(false)
	c.logger.Info("controller ready")

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-c.trigger:
			if !waitForDelay(ctx, c.config.rolloutDelay) {
				return nil
			}
			if err := c.reconcile(ctx); err != nil {
				c.logger.Error("reconciliation failed", "error", err)
				c.enqueue(nil)
			}
		}
	}
}

func waitForDelay(ctx context.Context, delay time.Duration) bool {
	if delay <= 0 {
		return true
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func (c *rolloutController) reconcile(ctx context.Context) error {
	configMap, err := c.client.CoreV1().ConfigMaps(c.config.namespace).Get(
		ctx,
		c.config.configMapName,
		metav1.GetOptions{},
	)
	if err != nil {
		return err
	}

	var patched bool
	err = retry.RetryOnConflict(retry.DefaultBackoff, func() error {
		deployment, getErr := c.client.AppsV1().Deployments(c.config.namespace).Get(
			ctx,
			c.config.deploymentName,
			metav1.GetOptions{},
		)
		if getErr != nil {
			return getErr
		}
		if deployment.Spec.Template.Annotations[c.config.annotationKey] == configMap.ResourceVersion {
			return nil
		}

		patch, marshalErr := rolloutPatch(deployment, c.config.annotationKey, configMap.ResourceVersion)
		if marshalErr != nil {
			return marshalErr
		}
		if _, patchErr := c.client.AppsV1().Deployments(c.config.namespace).Patch(
			ctx,
			c.config.deploymentName,
			types.MergePatchType,
			patch,
			metav1.PatchOptions{},
		); patchErr != nil {
			return patchErr
		}
		patched = true
		return nil
	})
	if err != nil {
		return err
	}
	if patched {
		c.logger.Info(
			"deployment rollout requested",
			"namespace", c.config.namespace,
			"deployment", c.config.deploymentName,
			"configMap", c.config.configMapName,
			"resourceVersion", configMap.ResourceVersion,
		)
	}
	return nil
}

func rolloutPatch(deployment *appsv1.Deployment, annotationKey, resourceVersion string) ([]byte, error) {
	annotations := map[string]string{}
	for key, value := range deployment.Spec.Template.Annotations {
		annotations[key] = value
	}
	annotations[annotationKey] = resourceVersion

	return json.Marshal(map[string]any{
		"metadata": map[string]string{
			"resourceVersion": deployment.ResourceVersion,
		},
		"spec": map[string]any{
			"template": map[string]any{
				"metadata": map[string]any{
					"annotations": annotations,
				},
			},
		},
	})
}
