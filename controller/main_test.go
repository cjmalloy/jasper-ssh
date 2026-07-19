package main

import (
	"testing"
	"time"
)

func TestLoadConfig(t *testing.T) {
	t.Setenv("NAMESPACE", "jasper")
	t.Setenv("AUTHORIZED_KEYS_CONFIGMAP_NAME", "keys")
	t.Setenv("SSH_DEPLOYMENT_NAME", "ssh")
	t.Setenv("ROLLOUT_ANNOTATION_KEY", "example.com/version")
	t.Setenv("ROLLOUT_DELAY", "15s")
	t.Setenv("HEALTH_ADDRESS", ":9090")

	config, address, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if config.namespace != "jasper" ||
		config.configMapName != "keys" ||
		config.deploymentName != "ssh" ||
		config.annotationKey != "example.com/version" ||
		config.rolloutDelay != 15*time.Second ||
		address != ":9090" {
		t.Fatalf("unexpected configuration: %#v, address %q", config, address)
	}
}

func TestLoadConfigRejectsNegativeDelay(t *testing.T) {
	t.Setenv("AUTHORIZED_KEYS_CONFIGMAP_NAME", "keys")
	t.Setenv("SSH_DEPLOYMENT_NAME", "ssh")
	t.Setenv("ROLLOUT_DELAY", "-1s")

	if _, _, err := loadConfig(); err == nil {
		t.Fatal("loadConfig accepted a negative rollout delay")
	}
}

func TestLoadConfigUsesConservativeRolloutDelay(t *testing.T) {
	t.Setenv("AUTHORIZED_KEYS_CONFIGMAP_NAME", "keys")
	t.Setenv("SSH_DEPLOYMENT_NAME", "ssh")
	t.Setenv("ROLLOUT_DELAY", "")

	config, _, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if config.rolloutDelay != time.Minute {
		t.Fatalf("rolloutDelay = %v, want 1m", config.rolloutDelay)
	}
}
