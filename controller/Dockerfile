FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /controller .

FROM scratch
COPY --from=build /controller /controller
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/controller"]
