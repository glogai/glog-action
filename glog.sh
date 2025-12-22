#!/bin/bash

# Default list of languages
DEFAULT_LANGS=("cpp" "java" "javascript" "python" "kotlin" "php" "ruby" "csharp" "oss" "terraform" "secrets" "resolver" "docker" "inventory")

# Map of languages to image names
declare -A IMAGE_MAP=(
  [oss]="glog-scan-oss-cc90"
  [java]="glog-scan-java-b608"
  [ruby]="glog-scan-ruby-35d9"
  [terraform]="glog-scan-terraform-51c8 glog-scan-terraform-6b93"
  [cpp]="glog-scan-cpp-c97a"
  [inventory]="glog-scan-inventory-5a5b"
  [python]="glog-scan-python-5f95 glog-scan-python-0386"
  [secrets]="glog-scan-secrets-f27b"
  [csharp]="glog-scan-csharp-2feb"
  [php]="glog-scan-php-7d88 glog-scan-php-4719"
  [kotlin]="glog-scan-kotlin-d734"
  [resolver]="glog-scan-resolver-fbbb"
  [javascript]="glog-scan-javascript-0af1 glog-scan-javascript-3cb4"
  [docker]="glog-scan-docker-b5ea"
)

# Function to detect programming languages in the project directory
detect_languages() {
  local project_dir="$1"
  local -A languages
  for file in $(find "$project_dir" -type f); do
    case "${file##*.}" in
      c|cpp|h|hpp)        languages["cpp"]=1 ;;
      java|class)         languages["java"]=1 ;;
      js)                 languages["javascript"]=1 ;;
      py)                 languages["python"]=1 ;;
      kotlin|kt)          languages["kotlin"]=1 ;;
      php)                languages["php"]=1 ;;
      rb)                 languages["ruby"]=1 ;;
      cs)                 languages["csharp"]=1 ;;
      tf)                 languages["terraform"]=1 ;;
      git)                languages["git"]=1 ;;
    esac
    # Detect Dockerfiles by filename pattern
    case "$(basename "$file")" in
      Dockerfile|Dockerfile.*|*.dockerfile)  languages["docker"]=1 ;;
    esac
  done
  echo "${!languages[@]}"
}

# Function to scan language and path
scan_lang() {
    local lang=$1
    local path=$2
    local ignore=$3
    local client=$4
    local env=$5
    local registry=$6
    local images=()

    # Retrieve images for the specified language
    image_list=${IMAGE_MAP[$lang]}
    images=($image_list)
     echo "$images"

    for image_name in "${images[@]}"; do
      docker run --rm -e GLOGSERVICE="$GLOG_TOKEN" -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) -e SARIF_FORMAT_TYPE="GITHUB" -e IGNORE="$ignore" -e CLIENT="$client" -e ENV="$env" -e GLOG_IMAGE="$image_name" -v "$path":/app "$registry$image_name"
    done
}

# Parse arguments
SCAN=false
LANGUAGES=()
IGNORE=""
CLIENT=""
ENV=""
REGISTRY=""
PROJECT_PATH=$(pwd)
GLOG_TOKEN=$GLOG_TOKEN

while [[ $# -gt 0 ]]; do
    case $1 in
        scan)
            SCAN=true
            ;;
        --path)
            PROJECT_PATH="$2"
            shift
            ;;
        --lang)
            IFS=',' read -r -a LANGUAGES <<< "$2"
            shift
            ;;
        --client)
            CLIENT="$2"
            shift
            ;;
        --env)
            ENV="$2"
            shift
            ;;
        --glogtoken)
            GLOG_TOKEN="$2"
            shift
            ;;
        --ignore)
            IGNORE="$2"
            shift
            ;;
        --registry)
            REGISTRY="$2"
            shift
            ;;
        *)
            echo "Invalid option: $1"
            exit 1
            ;;
    esac
    shift
done

### Detect languages ###################################
if $SCAN; then
  if [ ${#LANGUAGES[@]} -eq 0 ]; then
    LANGUAGES=($(detect_languages "$PROJECT_PATH"))
  fi
fi

LANGUAGES+=('resolver')

########################################################

if $SCAN; then
  for lang in "${LANGUAGES[@]}"; do
      echo "Analyzing language: $lang"
      echo "Product location: $PROJECT_PATH"
      echo "Client: $CLIENT"
      echo "Env: $ENV"
      scan_lang "$lang" "$PROJECT_PATH" "$IGNORE" "$CLIENT" "$ENV" "$REGISTRY"
  done
fi
