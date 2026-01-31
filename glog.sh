#!/bin/bash
set -euo pipefail

# Default list of languages
DEFAULT_LANGS=("cpp" "java" "javascript" "python" "kotlin" "php" "ruby" "csharp" "oss" "terraform" "secrets" "resolver" "docker" "inventory")

# Map of languages to image names
declare -A IMAGE_MAP=(
  [oss]="glog-scan-oss-cc90"
  [java]="glog-scan-java-b608 glog-scan-java-3e9a glog-scan-java-e2b1"
  [ruby]="glog-scan-ruby-35d9"
  [terraform]="glog-scan-terraform-51c8 glog-scan-terraform-6b93 glog-scan-terraform-8bd5"
  [cpp]="glog-scan-cpp-c97a"
  [inventory]="glog-scan-inventory-5a5b"
  [python]="glog-scan-python-5f95 glog-scan-python-0386 glog-scan-python-4166"
  [secrets]="glog-scan-secrets-f27b"
  [csharp]="glog-scan-csharp-2feb"
  [php]="glog-scan-php-7d88 glog-scan-php-4719 glog-scan-php-ba41"
  [kotlin]="glog-scan-kotlin-d734"
  [resolver]="glog-scan-resolver-fbbb"
  [javascript]="glog-scan-javascript-0af1 glog-scan-javascript-3cb4"
  [docker]="glog-scan-docker-b5ea",
  [objectscript]="glog-scan-objectscript-b977"
)

usage() {
  cat <<'EOF'
Usage:
  glog.sh [clean] [scan] [options]

Commands (can be combined and will run in the order provided):
  clean    Clean PATH/.glog directory contents
  scan     Run scanners

Options:
  --path PATH                Project/workspace path (default: pwd)
  --lang l1,l2               Languages list (default: auto-detect)
  --client CLIENT
  --env ENV
  --glogtoken TOKEN
  --ignore PATTERN
  --registry REGISTRY_PREFIX (example: "ghcr.io/glogai/")
  --sarif-format-type TYPE   Default: GITHUB
EOF
}

detect_languages() {
  local project_dir="$1"
  local -A languages=()

  while IFS= read -r -d '' file; do
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
      objectscript)       languages["cls"]=1 ;;
    esac

    case "$(basename "$file")" in
      Dockerfile|Dockerfile.*|*.dockerfile)  languages["docker"]=1 ;;
    esac
  done < <(find "$project_dir" -type f -print0)

  echo "${!languages[@]}"
}

clean_glog() {
  local workspace="$1"

  echo "Checking .glog directory..."
  if [ -d "$workspace/.glog" ]; then
    echo ".glog directory exists. Cleaning up..."
    # Removes everything inside .glog (including hidden files)
    find "$workspace/.glog" -mindepth 1 -exec rm -rf {} +
  else
    echo "$workspace .glog directory does not exist."
  fi
}

scan_lang() {
  local lang=$1
  local path=$2
  local ignore=$3
  local client=$4
  local env=$5
  local registry=$6
  local sarif_format_type=$7

  local image_list="${IMAGE_MAP[$lang]:-}"
  if [[ -z "$image_list" ]]; then
    echo "No images configured for language: $lang (skipping)"
    return 0
  fi

  local images=($image_list)

  for image_name in "${images[@]}"; do
    docker run --rm \
      -e GLOGSERVICE="${GLOG_TOKEN}" \
      -e HOST_UID="$(id -u)" \
      -e HOST_GID="$(id -g)" \
      -e SARIF_FORMAT_TYPE="$sarif_format_type" \
      -e IGNORE="$ignore" \
      -e CLIENT="$client" \
      -e ENV="$env" \
      -e GLOG_IMAGE="$image_name" \
      -v "$path":/app \
      "${registry}${image_name}"
  done
}

# -----------------------
# Defaults
# -----------------------
COMMANDS=()

LANGUAGES=()
IGNORE=""
CLIENT=""
ENV=""
REGISTRY=""
PROJECT_PATH="$(pwd)"
GLOG_TOKEN="${GLOG_TOKEN:-}"
SARIF_FORMAT_TYPE="GITHUB"

# -----------------------
# Parse args (commands can be mixed: clean scan ...)
# -----------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    clean|scan)
      COMMANDS+=("$1")
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
    --sarif-format-type)
      SARIF_FORMAT_TYPE="$2"
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "Invalid option/command: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ ${#COMMANDS[@]} -eq 0 ]]; then
  usage
  exit 1
fi

# -----------------------
# Execute commands in order given
# -----------------------
for cmd in "${COMMANDS[@]}"; do
  case "$cmd" in
    clean)
      clean_glog "$PROJECT_PATH"
      ;;
    scan)
      if [[ ${#LANGUAGES[@]} -eq 0 ]]; then
        # shellcheck disable=SC2207
        LANGUAGES=($(detect_languages "$PROJECT_PATH"))
      fi

      # Always add resolver
      LANGUAGES+=('resolver')

      for lang in "${LANGUAGES[@]}"; do
        echo "Analyzing language: $lang"
        echo "Product location: $PROJECT_PATH"
        echo "Client: $CLIENT"
        echo "Env: $ENV"
        echo "SARIF_FORMAT_TYPE: $SARIF_FORMAT_TYPE"
        scan_lang "$lang" "$PROJECT_PATH" "$IGNORE" "$CLIENT" "$ENV" "$REGISTRY" "$SARIF_FORMAT_TYPE"
      done
      ;;
  esac
done
