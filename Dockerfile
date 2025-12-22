# Edge Functions server
#
# Supabase Edge Runtime with this project's JavaScript functions baked in.
# A small router (docker/edge-runtime/main) dispatches /<function-name>
# requests to isolated workers, the same way the hosted platform and the
# Supabase CLI do. Secrets are provided at runtime through environment
# variables and are never copied into the image (see .dockerignore).
#
#   docker build -t saas-backend-functions .
#   docker run -p 9000:9000 --env-file <file> saas-backend-functions

FROM supabase/edge-runtime:v1.69.28

WORKDIR /home/deno

COPY docker/edge-runtime/main ./main
COPY supabase/functions ./functions

EXPOSE 9000

CMD ["start", "--main-service", "/home/deno/main", "--port", "9000"]
