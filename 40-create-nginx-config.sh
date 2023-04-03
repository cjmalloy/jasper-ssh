echo "Writing Nginx Config"

config="
server {
    listen       8022;
    listen  [::]:8022;
    server_name  localhost;

    proxy_set_header User-Tag \"${USER_TAG}\";
    proxy_set_header User-Role \"${USER_ROLE}\";
    proxy_set_header Local-Origin \"${LOCAL_ORIGIN}\";
    proxy_set_header Read-Access \"${READ_ACCESS}\";
    proxy_set_header Write-Access \"${WRITE_ACCESS}\";
    proxy_set_header Tag-Read-Access \"${TAG_READ_ACCESS}\";
    proxy_set_header Tag-Write-Access \"${TAG_WRITE_ACCESS}\";

    location / {
        proxy_pass ${UPSTREAM-http://localhost:8081/};
    }
}
"
echo "$config"
echo "$config" > /etc/nginx/conf.d/default.conf
echo "Wrote to /etc/nginx/conf.d/default.conf"
