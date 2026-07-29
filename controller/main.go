package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	config, healthAddress, err := loadConfig()
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(2)
	}

	clusterConfig, err := rest.InClusterConfig()
	if err != nil {
		logger.Error("in-cluster authentication failed", "error", err)
		os.Exit(1)
	}
	client, err := kubernetes.NewForConfig(clusterConfig)
	if err != nil {
		logger.Error("Kubernetes client creation failed", "error", err)
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	controller := newRolloutController(client, config, logger)
	server := newHealthServer(healthAddress, &controller.ready)
	serverErrors := make(chan error, 1)
	go func() {
		logger.Info("health server listening", "address", healthAddress)
		serverErrors <- server.ListenAndServe()
	}()

	runErrors := make(chan error, 1)
	go func() {
		runErrors <- controller.run(ctx)
	}()

	select {
	case err = <-runErrors:
		if err != nil {
			logger.Error("controller stopped", "error", err)
		}
	case err = <-serverErrors:
		if err == http.ErrServerClosed {
			err = nil
		} else {
			logger.Error("health server stopped", "error", err)
		}
	case <-ctx.Done():
		logger.Info("shutdown requested")
	}
	cancel()

	shutdownContext, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if shutdownErr := server.Shutdown(shutdownContext); shutdownErr != nil {
		logger.Error("health server shutdown failed", "error", shutdownErr)
	}
	if err != nil {
		os.Exit(1)
	}
}

func loadConfig() (controllerConfig, string, error) {
	config := controllerConfig{
		namespace:      envOrDefault("NAMESPACE", "default"),
		configMapName:  os.Getenv("AUTHORIZED_KEYS_CONFIGMAP_NAME"),
		deploymentName: os.Getenv("SSH_DEPLOYMENT_NAME"),
		annotationKey: envOrDefault(
			"ROLLOUT_ANNOTATION_KEY",
			"jasper-ssh.cjmalloy.com/authorized-keys-resource-version",
		),
	}
	if config.configMapName == "" {
		return controllerConfig{}, "", fmt.Errorf("AUTHORIZED_KEYS_CONFIGMAP_NAME is required")
	}
	if config.deploymentName == "" {
		return controllerConfig{}, "", fmt.Errorf("SSH_DEPLOYMENT_NAME is required")
	}

	delay := envOrDefault("ROLLOUT_DELAY", "0s")
	rolloutDelay, err := time.ParseDuration(delay)
	if err != nil || rolloutDelay < 0 {
		return controllerConfig{}, "", fmt.Errorf("ROLLOUT_DELAY must be a non-negative Go duration")
	}
	config.rolloutDelay = rolloutDelay

	return config, envOrDefault("HEALTH_ADDRESS", ":8080"), nil
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
