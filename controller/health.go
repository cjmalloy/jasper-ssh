package main

import (
	"net/http"
	"sync/atomic"
	"time"
)

func newHealthServer(address string, ready *atomic.Bool) *http.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/livez", func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/readyz", func(response http.ResponseWriter, _ *http.Request) {
		if !ready.Load() {
			http.Error(response, "not ready", http.StatusServiceUnavailable)
			return
		}
		response.WriteHeader(http.StatusOK)
	})
	return &http.Server{
		Addr:              address,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
}
