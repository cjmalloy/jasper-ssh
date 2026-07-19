package main

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestHealthEndpoints(t *testing.T) {
	var ready atomic.Bool
	server := newHealthServer(":0", &ready)

	assertStatus(t, server.Handler, "/livez", http.StatusOK)
	assertStatus(t, server.Handler, "/readyz", http.StatusServiceUnavailable)
	ready.Store(true)
	assertStatus(t, server.Handler, "/readyz", http.StatusOK)
}

func assertStatus(t *testing.T, handler http.Handler, path string, expected int) {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, path, nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != expected {
		t.Fatalf("%s status = %d, want %d", path, response.Code, expected)
	}
}
