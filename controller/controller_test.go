package main

import (
	"context"
	"io"
	"log/slog"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/kubernetes/fake"
	ktesting "k8s.io/client-go/testing"
)

const testAnnotation = "example.com/authorized-keys-version"

func TestReconcilePatchesDeployment(t *testing.T) {
	client := fake.NewClientset(testConfigMap("42"), testDeployment(""))
	controller := testController(client)

	if err := controller.reconcile(context.Background()); err != nil {
		t.Fatalf("reconcile: %v", err)
	}

	deployment, err := client.AppsV1().Deployments("test").Get(
		context.Background(),
		"ssh",
		metav1.GetOptions{},
	)
	if err != nil {
		t.Fatalf("get deployment: %v", err)
	}
	if got := deployment.Spec.Template.Annotations[testAnnotation]; got != "42" {
		t.Fatalf("annotation = %q, want 42", got)
	}
	if got := deployment.Spec.Template.Annotations["existing"]; got != "preserved" {
		t.Fatalf("existing annotation = %q, want preserved", got)
	}
}

func TestReconcileIsIdempotent(t *testing.T) {
	client := fake.NewClientset(testConfigMap("42"), testDeployment("42"))
	controller := testController(client)

	if err := controller.reconcile(context.Background()); err != nil {
		t.Fatalf("reconcile: %v", err)
	}

	for _, action := range client.Actions() {
		if action.GetVerb() == "patch" {
			t.Fatal("reconcile patched a deployment already at the ConfigMap version")
		}
	}
}

func TestReconcileRetriesConflict(t *testing.T) {
	client := fake.NewClientset(testConfigMap("42"), testDeployment(""))
	conflicts := 0
	client.PrependReactor("patch", "deployments", func(ktesting.Action) (bool, runtime.Object, error) {
		if conflicts == 0 {
			conflicts++
			return true, nil, apierrors.NewConflict(
				schema.GroupResource{Group: "apps", Resource: "deployments"},
				"ssh",
				nil,
			)
		}
		return false, nil, nil
	})

	if err := testController(client).reconcile(context.Background()); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if conflicts != 1 {
		t.Fatalf("conflicts = %d, want 1", conflicts)
	}
}

func testController(client *fake.Clientset) *rolloutController {
	return newRolloutController(client, controllerConfig{
		namespace:      "test",
		configMapName:  "keys",
		deploymentName: "ssh",
		annotationKey:  testAnnotation,
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func testConfigMap(resourceVersion string) *corev1.ConfigMap {
	return &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{
		Namespace:       "test",
		Name:            "keys",
		ResourceVersion: resourceVersion,
	}}
}

func testDeployment(annotationValue string) *appsv1.Deployment {
	annotations := map[string]string{"existing": "preserved"}
	if annotationValue != "" {
		annotations[testAnnotation] = annotationValue
	}
	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Namespace:       "test",
			Name:            "ssh",
			ResourceVersion: "10",
		},
		Spec: appsv1.DeploymentSpec{
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Annotations: annotations},
			},
		},
	}
}
