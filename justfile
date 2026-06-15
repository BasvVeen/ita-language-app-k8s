registry := "italanguageappregistry.azurecr.io"
image := "ita-language-app"
tag := "latest"

# Build the image, tagging both the given tag and latest
build:
    docker build -t {{registry}}/{{image}}:{{tag}} -t {{registry}}/{{image}}:latest .

# Build then push both tags
push: build
    docker push {{registry}}/{{image}}:{{tag}}
    docker push {{registry}}/{{image}}:latest
