#!/bin/bash
set -euo pipefail

DEFAULT_LANGS=("cpp" "java" "javascript" "python" "kotlin" "php" "ruby" "csharp" "oss" "terraform" "secrets" "resolver" "inventory" "objectscript" "go") #"docker"

declare -A IMAGE_MAP=(
  [oss]="glog-scan-oss-cc90"
  [java]="glog-scan-java-b608 glog-scan-java-3e9a glog-scan-java-e2b1"
  [ruby]="glog-scan-ruby-35d9"
  [terraform]="glog-scan-terraform-51c8 glog-scan-terraform-6b93 glog-scan-terraform-8bd5"
  [cpp]="glog-scan-cpp-c97a"
  [inventory]="glog-scan-inventory-5a5b"
  [python]="glog-scan-python-5f95 glog-scan-python-0386 glog-scan-python-4166"
  [secrets]="glog-scan-secrets-f27b"
  [csharp]="glog-scan-csharp-b460 glog-scan-csharp-6c24"
  [php]="glog-scan-php-7d88 glog-scan-php-4719 glog-scan-php-ba41"
  [kotlin]="glog-scan-kotlin-d734"
  [resolver]="glog-scan-resolver-fbbb"
  [javascript]="glog-scan-javascript-0af1 glog-scan-javascript-3cb4"
  #[docker]="glog-scan-docker-b5ea"
  [objectscript]="glog-scan-objectscript-b977"
  [go]="glog-scan-go-cb38 glog-scan-go-c6d3"
)

usage() {
  cat <<'EOF'
Glog.AI Scanner CLI
Usage: glog.sh [clean] [scan] [options]

Options:
  --path PATH               Project path to scan (default: current dir)
  --lang l1,l2               Languages list (default: auto-detect)
  --client CLIENT           Client identifier for Glog.AI
  --env ENV                 Environment (dev, stage, prod)
  --glogtoken TOKEN         Glog API Token
  --registry REGISTRY       Docker registry prefix (default: ghcr.io/glogai/)
  --ignore PATTERN          Patterns to ignore
  --sarif-format-type TYPE   Default: GITHUB
  --files FILE1,FILE2      Comma-separated list of files to scan relative to --path
EOF
}

cleanup() {
  if [[ -n "${TEMP_SCAN_DIR:-}" && -d "${TEMP_SCAN_DIR:-}" ]]; then
    rm -rf "$TEMP_SCAN_DIR"
  fi
}

trap cleanup EXIT

persist_scoped_scan_artifacts() {
  local scan_path="$1"
  local project_path="$2"

  if [[ "$scan_path" == "$project_path" ]]; then
    return
  fi

  if [[ ! -d "$scan_path/.glog" ]]; then
    echo "No .glog artifacts found in scoped scan directory."
    return
  fi

  mkdir -p "$project_path/.glog"
  cp -a "$scan_path/.glog/." "$project_path/.glog/"
  echo "Persisted scoped scan artifacts to $project_path/.glog"
}

detect_languages() {
  local project_dir="$1"
  local -A languages=()

  while IFS= read -r -d '' file; do
    case "${file##*.}" in
      c|cpp|h|hpp)        languages["cpp"]=1 ;;
      java|class)         languages["java"]=1 ;;
      js|ts|jsx|tsx)      languages["javascript"]=1 ;;
      py)                 languages["python"]=1 ;;
      kt|kotlin)          languages["kotlin"]=1 ;;
      php)                languages["php"]=1 ;;
      rb)                 languages["ruby"]=1 ;;
      cs)                 languages["csharp"]=1 ;;
      tf)                 languages["terraform"]=1 ;;
      cls)                languages["objectscript"]=1 ;;
      git)                languages["git"]=1 ;;
      objectscript)       languages["cls"]=1 ;;
      go)                 languages["go"]=1 ;;
    esac

    # case "$(basename "$file")" in
    #   Dockerfile|Dockerfile.*|*.dockerfile)  languages["docker"]=1 ;;
    # esac
  done < <(find "$project_dir" -maxdepth 15 -type f -not -path '*/.git/*' -print0)

  echo "${!languages[@]}"
}

prepare_scoped_files_dir() {
  local project_dir="$1"
  shift
  local input_files=("$@")

  TEMP_SCAN_DIR="$(mktemp -d)"
  local trimmed_file=""
  local src=""
  local dest=""
  local rel=""

  for file in "${input_files[@]}"; do
    trimmed_file="$(echo "$file" | xargs)"

    if [[ -z "$trimmed_file" ]]; then
      continue
    fi

    case "$trimmed_file" in
      /*|../*|*/../*|*"/.."|*"../"*)
        echo "Invalid file path: $trimmed_file"
        exit 1
        ;;
    esac

    src="$project_dir/$trimmed_file"

    if [[ ! -f "$src" ]]; then
      echo "File not found: $trimmed_file"
      exit 1
    fi

    dest="$TEMP_SCAN_DIR/$trimmed_file"
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
  done

  echo "$TEMP_SCAN_DIR"
}


scan_lang() {
  local lang=$1
  local path=$2
  local ignore=$3
  local client=$4
  local env=$5
  local registry=$6
  local sarif_format_type=$7
  local resolver_upload=$8

  local image_list="${IMAGE_MAP[$lang]:-}"
  if [[ -z "$image_list" ]]; then
    return 0
  fi

  for image_name in $image_list; do
    if [[ -n "${GLOG_DEPSCAN_VDB_VOLUME:-}" ]]; then
      if ! docker volume inspect "${GLOG_DEPSCAN_VDB_VOLUME}" > /dev/null 2>&1; then
        echo "Creating Docker volume: ${GLOG_DEPSCAN_VDB_VOLUME}"
        docker volume create "${GLOG_DEPSCAN_VDB_VOLUME}"
      fi
    fi
    echo "--> Running scanner: ${registry}${image_name}"
    docker run --pull always --rm \
      -e GLOGSERVICE="${GLOG_TOKEN}" \
      -e GLOG_TOKEN="${GLOG_TOKEN}" \
      -e HOST_UID="$(id -u)" \
      -e HOST_GID="$(id -g)" \
      -e SARIF_FORMAT_TYPE="$sarif_format_type" \
      -e RESOLVER_UPLOAD="$resolver_upload" \
      -e IGNORE="$ignore" \
      -e CLIENT="$client" \
      -e ENV="$env" \
      -e GLOG_IMAGE="$image_name" \
      ${GLOG_DEPSCAN_VDB_VOLUME:+-e GLOG_DEPSCAN_VDB_VOLUME="${GLOG_DEPSCAN_VDB_VOLUME}"} \
      ${VDB_APP_ONLY:+-e VDB_APP_ONLY="${VDB_APP_ONLY}"} \
      ${VDB_HOME:+-e VDB_HOME="${VDB_HOME}"} \
      ${VDB_DATABASE_URL:+-e VDB_DATABASE_URL="${VDB_DATABASE_URL}"} \
      ${VDB_AGE_HOURS:+-e VDB_AGE_HOURS="${VDB_AGE_HOURS}"} \
      -v "$path":/app \
      ${GLOG_DEPSCAN_VDB_VOLUME:+-v "${GLOG_DEPSCAN_VDB_VOLUME}:${VDB_HOME:-/vdb}"} \
      "${registry}${image_name}"
  done
}


COMMANDS=()

LANGUAGES=()
IGNORE=""
CLIENT=""
ENV=""
REGISTRY="ghcr.io/glogai/"
PROJECT_PATH="$(pwd)"
GLOG_TOKEN="${GLOG_TOKEN:-}"
SARIF_FORMAT_TYPE="${SARIF_FORMAT_TYPE:-GITHUB}"
FILES=()
TEMP_SCAN_DIR=""
RESOLVER_UPLOAD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    clean|scan) COMMANDS+=("$1"); shift ;;
    --path) PROJECT_PATH="$2"; shift 2 ;;
    --files) IFS=',' read -r -a FILES <<< "$2"; shift 2 ;;
    --lang) IFS=',' read -r -a LANGUAGES <<< "$2"; shift 2 ;;
    --client) CLIENT="$2"; shift 2 ;;
    --env) ENV="$2"; shift 2 ;;
    --glogtoken) GLOG_TOKEN="$2"; shift 2 ;;
    --ignore) IGNORE="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --sarif-format-type) SARIF_FORMAT_TYPE="$2"; shift 2 ;;
     -u|--upload) RESOLVER_UPLOAD=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ ${#COMMANDS[@]} -eq 0 ]]; then
  usage; exit 1
fi

for cmd in "${COMMANDS[@]}"; do
  case "$cmd" in
    clean)
      echo "Cleaning .glog directory in $PROJECT_PATH..."
      if [ -d "$PROJECT_PATH/.glog" ]; then
        rm -rf "$PROJECT_PATH"/.glog/*
      fi
      ;;
    scan)
      SCAN_PATH="$PROJECT_PATH"

      if [[ ${#FILES[@]} -gt 0 ]]; then
        echo "Preparing scoped scan for selected files..."
        SCAN_PATH="$(prepare_scoped_files_dir "$PROJECT_PATH" "${FILES[@]}")"
        echo "Scoped scan directory: $SCAN_PATH"
      fi

      if [[ ${#LANGUAGES[@]} -eq 0 ]]; then
        # shellcheck disable=SC2207
        LANGUAGES=($(detect_languages "$SCAN_PATH"))
      fi

      LANGUAGES+=('resolver')

      for lang in "${LANGUAGES[@]}"; do
        echo "Analyzing language: $lang"
        scan_lang "$lang" "$SCAN_PATH" "$IGNORE" "$CLIENT" "$ENV" "$REGISTRY" "$SARIF_FORMAT_TYPE" "$RESOLVER_UPLOAD"
      done

      persist_scoped_scan_artifacts "$SCAN_PATH" "$PROJECT_PATH"
      ;;
  esac
done
