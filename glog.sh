#!/bin/bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_LANGS=("cpp" "java" "javascript" "python" "kotlin" "php" "ruby" "csharp" "oss" "terraform" "secrets" "resolver" "objectscript" "go") #"docker"

declare -A IMAGE_MAP=(
  [oss]="glog-scan-oss-cc90"
  [java]="glog-scan-java-b608 glog-scan-java-3e9a glog-scan-java-e2b1"
  [ruby]="glog-scan-ruby-35d9"
  [terraform]="glog-scan-terraform-51c8 glog-scan-terraform-6b93 glog-scan-terraform-8bd5"
  [cpp]="glog-scan-cpp-c97a"
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
  # CycloneDX SBOM generator (cdxgen). Writes /app/.glog/sbom.cdx.json which
  # the resolver (running after) uploads to /api/sca/resolver/sbom/.
  [sbom]="glog-scan-sbom-9828"
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
  --sarif-format-type TYPE   SARIF structure for this platform: GITHUB (default), AZURE, GITLAB, STANDARD
  --server-sarif-format-type TYPE  Second SARIF format used for the server upload (usually STANDARD);
                            when set and different, the resolver runs twice
  --files FILE1,FILE2      Comma-separated list of files to scan relative to --path
  -u|--upload               Upload scan results to On-Prem Dashboard (SARIF, and SBOM if --sbom)
  --inventory               Force the inventory scanner to run (in addition to detected languages)
  --sbom                    Generate a CycloneDX SBOM via resolver (--with-sbom)
  --sbom-only               Skip SARIF, only produce the SBOM (implies --sbom)
  --scl-uuid UUID           Source Code Location UUID to bind SARIF/SBOM uploads to
  --privacy-tier TIER       full (default) | metrics | none. Controls what leaves the tenant.
  --mock-resolver           Serve AI answers from the server-side OpenAI mock (no OpenAI cost;
                            simulated latency and Tier 5 rate limits). Testing only.
  --api-url URL             Override Glog.AI server URL (default: from image config)
  --supply-chain             Run the bounded supply-chain scan
  --supply-chain-policy FILE  Enable scanning with a policy file relative to --path
  --supply-chain-offline      Disable registry network access; use only the persistent cache
  --supply-chain-cache-only   Use only the persistent metadata cache
  --supply-chain-fail-on LEVEL  Policy severity threshold: INFO, LOW, MEDIUM, HIGH or CRITICAL
   --supply-chain-format FORMAT  Output: json, sarif or both (default: both)
   --rebuild                    Run the reproducible-build worker on this runner
   --rebuild-artifact PATH      Package artifact on this runner
   --rebuild-manifest PATH      Optional published path-to-SHA256 manifest (server baseline otherwise)
   --rebuild-package NAME       Package name
   --rebuild-version VERSION    Package version
   --rebuild-ecosystem NAME     npm, pypi, go, cargo, maven or rubygems
   --rebuild-image IMAGE        Rebuild worker image


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

verify_scan_artifacts() {
  local project_path="$1"
  local glog_dir="$project_path/.glog"
  local missing=0

  echo "--- Glog artifact summary ($glog_dir) ---"
  if [[ -d "$glog_dir" ]]; then
    ls -l "$glog_dir" || true
  else
    echo "  (no .glog directory was produced)"
  fi

  if [[ "$SBOM_ONLY" != "true" ]]; then
    if [[ -s "$glog_dir/glog-scan.sarif" ]]; then
      echo "  SARIF: OK ($glog_dir/glog-scan.sarif)"
    else
      echo "Glog: SARIF results are missing." >&2
      missing=1
    fi
  fi

  if [[ "$WITH_SBOM" == "true" ]]; then
    if compgen -G "$glog_dir/*.cdx.json" > /dev/null; then
      echo "  SBOM: OK ($(ls "$glog_dir"/*.cdx.json | tr '\n' ' '))"
    else
      echo "Glog: SBOM results are missing." >&2
      missing=1
    fi
  fi

  if [[ "$RESOLVER_UPLOAD" == "true" ]]; then
    echo "  Upload: requested (server ingestion is reported by the resolver above)"
  else
    echo "  Upload: disabled (pass on-prem-upload=true / --upload to send results to the server)"
  fi
  echo "----------------------------------------"

  if [[ "$missing" -ne 0 ]]; then
    echo "Glog: expected scan artifacts are missing — failing the step." >&2
    return 1
  fi
  return 0
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
        echo "Invalid file path: $trimmed_file" >&2
        exit 1
        ;;
    esac

    src="$project_dir/$trimmed_file"

    if [[ ! -f "$src" ]]; then
      echo "File not found: $trimmed_file" >&2
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
  local privacy_tier=${9:-full}
  local api_url=${10:-}

  local image_list="${IMAGE_MAP[$lang]:-}"
  if [[ -z "$image_list" ]]; then
    echo "  (skipping '$lang': no scanner image mapped — use --sbom / --inventory flags, not --lang)"
    return 0
  fi

  for image_name in $image_list; do
    if [[ -n "${GLOG_DEPSCAN_VDB_VOLUME:-}" ]]; then
      if ! docker volume inspect "${GLOG_DEPSCAN_VDB_VOLUME}" > /dev/null 2>&1; then
        echo "Creating Docker volume: ${GLOG_DEPSCAN_VDB_VOLUME}"
        docker volume create "${GLOG_DEPSCAN_VDB_VOLUME}"
      fi
    fi

    EXTRA_ARGS=()
    if [[ "$image_name" == glog-scan-sbom-9828* ]]; then
      # SBOM (cdxgen + mvnw) needs network egress to Maven Central / npm registry
      # and a persistent Maven cache to avoid re-downloading plugins each run.
      EXTRA_ARGS+=(--network host)
      mkdir -p "${HOME}/.glog-m2"
      EXTRA_ARGS+=(-v "${HOME}/.glog-m2:/root/.m2")
      EXTRA_ARGS+=(-e CDXGEN_TIMEOUT_MS=600000)
      EXTRA_ARGS+=(-e FETCH_LICENSE=false)
    fi

    local run_image="${registry}${image_name}"

    docker run --pull always --rm \
      "${EXTRA_ARGS[@]}" \
      -e GLOGSERVICE="${GLOG_TOKEN}" \
      -e GLOG_TOKEN="${GLOG_TOKEN}" \
      -e HOST_UID="$(id -u)" \
      -e HOST_GID="$(id -g)" \
      -e SARIF_FORMAT_TYPE="$sarif_format_type" \
      -e RESOLVER_UPLOAD="$resolver_upload" \
      -e WITH_SBOM="${WITH_SBOM:-false}" \
      -e SBOM_ONLY="${SBOM_ONLY:-false}" \
      -e SBOM_MODE="$([ "$resolver_upload" = "true" ] && echo persist || echo stateless)" \
      -e FORCE_INVENTORY="${FORCE_INVENTORY:-false}" \
      -e WITH_INVENTORY="${FORCE_INVENTORY:-false}" \
      -e SCL_UUID="${SCL_UUID:-}" \
      -e PRIVACY_TIER="$privacy_tier" \
       -e MOCK_RESOLVER="${MOCK_RESOLVER:-false}" \
       -e SUPPLY_CHAIN_ENABLED="${SUPPLY_CHAIN_ENABLED:-false}" \
       -e SUPPLY_CHAIN_POLICY="${SUPPLY_CHAIN_POLICY:-}" \
       -e SUPPLY_CHAIN_OFFLINE="${SUPPLY_CHAIN_OFFLINE:-false}" \
       -e SUPPLY_CHAIN_CACHE_ONLY="${SUPPLY_CHAIN_CACHE_ONLY:-false}" \
       -e SUPPLY_CHAIN_FAIL_ON="${SUPPLY_CHAIN_FAIL_ON:-}" \
       -e SUPPLY_CHAIN_FORMAT="${SUPPLY_CHAIN_FORMAT:-both}" \
      ${api_url:+-e GLOG_API_URL="$api_url"} \
      -e IGNORE="$ignore" \
      -e CLIENT="$client" \
      -e ENV="$env" \
      -e GLOG_IMAGE="$image_name" \
      -e HOST_PROJECT_PATH="$path" \
      -e GLOG_COMPONENT="${GLOG_COMPONENT:-$(basename "$path")}" \
      -e GLOG_BRANCH="${GLOG_BRANCH:-${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-${BUILD_SOURCEBRANCHNAME:-${CI_COMMIT_REF_NAME:-${BRANCH_NAME:-}}}}}}" \
      -e GLOG_TRIAGE_TIMEOUT_MINUTES="${GLOG_TRIAGE_TIMEOUT_MINUTES:-1440}" \
      -e GLOG_SOCKET_TIMEOUT_MS="${GLOG_SOCKET_TIMEOUT_MS:-1800000}" \
      -e GLOG_CONNECT_TIMEOUT_MS="${GLOG_CONNECT_TIMEOUT_MS:-60000}" \
      -e GLOG_CONNECTION_REQUEST_TIMEOUT_MS="${GLOG_CONNECTION_REQUEST_TIMEOUT_MS:-60000}" \
      -e GLOG_PROFILE="${GLOG_PROFILE:-}" \
      -e GLOG_REMEDIATION_BULK="${GLOG_REMEDIATION_BULK:-1}" \
      -e GLOG_REMEDIATION_BATCH="${GLOG_REMEDIATION_BATCH:-20}" \
      -e GLOG_REMEDIATION_BATCH_LINGER_MS="${GLOG_REMEDIATION_BATCH_LINGER_MS:-750}" \
      -e GLOG_REMEDIATION_INFLIGHT_BATCHES="${GLOG_REMEDIATION_INFLIGHT_BATCHES:-8}" \
      -e GLOG_FP_FROM_VALIDATE="${GLOG_FP_FROM_VALIDATE:-true}" \
      ${GLOG_DEPSCAN_VDB_VOLUME:+-e GLOG_DEPSCAN_VDB_VOLUME="${GLOG_DEPSCAN_VDB_VOLUME}"} \
      ${VDB_APP_ONLY:+-e VDB_APP_ONLY="${VDB_APP_ONLY}"} \
      ${VDB_HOME:+-e VDB_HOME="${VDB_HOME}"} \
      ${VDB_DATABASE_URL:+-e VDB_DATABASE_URL="${VDB_DATABASE_URL}"} \
      ${VDB_AGE_HOURS:+-e VDB_AGE_HOURS="${VDB_AGE_HOURS}"} \
      -v "$path":/app \
      ${GLOG_DEPSCAN_VDB_VOLUME:+-v "${GLOG_DEPSCAN_VDB_VOLUME}:${VDB_HOME:-/vdb}"} \
      "$run_image"

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
SERVER_SARIF_FORMAT_TYPE="${SERVER_SARIF_FORMAT_TYPE:-}"
FILES=()
TEMP_SCAN_DIR=""
RESOLVER_UPLOAD=false
WITH_SBOM=false
SBOM_ONLY=false
SCL_UUID=""
FORCE_INVENTORY=false
PRIVACY_TIER="${PRIVACY_TIER:-full}"
MOCK_RESOLVER="${MOCK_RESOLVER:-false}"
GLOG_API_URL="${GLOG_API_URL:-}"
SUPPLY_CHAIN_ENABLED="${SUPPLY_CHAIN_ENABLED:-false}"
SUPPLY_CHAIN_POLICY="${SUPPLY_CHAIN_POLICY:-}"
SUPPLY_CHAIN_OFFLINE="${SUPPLY_CHAIN_OFFLINE:-false}"
SUPPLY_CHAIN_CACHE_ONLY="${SUPPLY_CHAIN_CACHE_ONLY:-false}"
SUPPLY_CHAIN_FAIL_ON="${SUPPLY_CHAIN_FAIL_ON:-}"
SUPPLY_CHAIN_FORMAT="${SUPPLY_CHAIN_FORMAT:-both}"
REBUILD=false
REBUILD_ARTIFACT="${REBUILD_ARTIFACT:-}"
REBUILD_MANIFEST="${REBUILD_MANIFEST:-}"
REBUILD_PACKAGE="${REBUILD_PACKAGE:-}"
REBUILD_VERSION="${REBUILD_VERSION:-}"
REBUILD_ECOSYSTEM="${REBUILD_ECOSYSTEM:-}"
REBUILD_IMAGE="${REBUILD_IMAGE:-ghcr.io/glogai/glog-scan-rebuild-4673}"


while [[ $# -gt 0 ]]; do
  case "$1" in
    clean|scan) COMMANDS+=("$1"); shift ;;
    --path) PROJECT_PATH="$2"; shift 2 ;;
    --files) IFS=',' read -r -a FILES <<< "$2"; shift 2 ;;
    --lang)
      IFS=',' read -r -a _LANG_RAW <<< "$2"
      LANGUAGES=()
      for _l in "${_LANG_RAW[@]}"; do
        case "$_l" in
          sbom)      WITH_SBOM=true ;;
          inventory) FORCE_INVENTORY=true ;;
          *)         LANGUAGES+=("$_l") ;;
        esac
      done
      shift 2 ;;
    --client) CLIENT="$2"; shift 2 ;;
    --env) ENV="$2"; shift 2 ;;
    --glogtoken) GLOG_TOKEN="$2"; shift 2 ;;
    --ignore) IGNORE="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --sarif-format-type) SARIF_FORMAT_TYPE="$2"; shift 2 ;;
    --server-sarif-format-type) SERVER_SARIF_FORMAT_TYPE="$2"; shift 2 ;;
     -u|--upload) RESOLVER_UPLOAD=true; shift ;;
    --inventory) FORCE_INVENTORY=true; shift ;;
    --sbom) WITH_SBOM=true; shift ;;
    --sbom-only) SBOM_ONLY=true; WITH_SBOM=true; shift ;;
    --scl-uuid) SCL_UUID="$2"; shift 2 ;;
    --privacy-tier) PRIVACY_TIER="$2"; shift 2 ;;
    --mock-resolver) MOCK_RESOLVER=true; shift ;;
    --api-url) GLOG_API_URL="$2"; shift 2 ;;
    --supply-chain) SUPPLY_CHAIN_ENABLED=true; shift ;;
    --supply-chain-policy) SUPPLY_CHAIN_POLICY="$2"; SUPPLY_CHAIN_ENABLED=true; shift 2 ;;
    --supply-chain-offline) SUPPLY_CHAIN_OFFLINE=true; SUPPLY_CHAIN_ENABLED=true; shift ;;
    --supply-chain-cache-only) SUPPLY_CHAIN_CACHE_ONLY=true; SUPPLY_CHAIN_ENABLED=true; shift ;;
    --supply-chain-fail-on) SUPPLY_CHAIN_FAIL_ON="$2"; SUPPLY_CHAIN_ENABLED=true; shift 2 ;;
     --supply-chain-format) SUPPLY_CHAIN_FORMAT="$2"; SUPPLY_CHAIN_ENABLED=true; shift 2 ;;
     --rebuild) REBUILD=true; shift ;;
     --rebuild-artifact) REBUILD_ARTIFACT="$2"; shift 2 ;;
     --rebuild-manifest) REBUILD_MANIFEST="$2"; shift 2 ;;
     --rebuild-package) REBUILD_PACKAGE="$2"; shift 2 ;;
     --rebuild-version) REBUILD_VERSION="$2"; shift 2 ;;
     --rebuild-ecosystem) REBUILD_ECOSYSTEM="$2"; shift 2 ;;
     --rebuild-image) REBUILD_IMAGE="$2"; shift 2 ;;
     -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

case "$PRIVACY_TIER" in
  full|metrics|none) ;;
  *) echo "Invalid --privacy-tier: $PRIVACY_TIER (expected: full, metrics, none)"; exit 1 ;;
esac

export WITH_SBOM SBOM_ONLY SCL_UUID FORCE_INVENTORY PRIVACY_TIER GLOG_API_URL MOCK_RESOLVER
export SUPPLY_CHAIN_ENABLED SUPPLY_CHAIN_POLICY SUPPLY_CHAIN_OFFLINE SUPPLY_CHAIN_CACHE_ONLY SUPPLY_CHAIN_FAIL_ON SUPPLY_CHAIN_FORMAT
if [[ "$MOCK_RESOLVER" == "true" ]]; then
  echo "WARNING: --mock-resolver is ON - AI answers are generated by the offline mock (no OpenAI cost). Results are NOT real remediations."
fi

echo "Glog scan options: WITH_SBOM=$WITH_SBOM SBOM_ONLY=$SBOM_ONLY FORCE_INVENTORY=$FORCE_INVENTORY RESOLVER_UPLOAD=$RESOLVER_UPLOAD SCL_UUID=${SCL_UUID:-<auto>}"
if [[ "$WITH_SBOM" == "true" && "$RESOLVER_UPLOAD" != "true" ]]; then
  echo "Note: SBOM will be written locally to .glog/ only. To send it to the Glog server pass on-prem-upload=true."
fi

if [[ ${#COMMANDS[@]} -eq 0 ]]; then
  usage; exit 1
fi

if [[ -n "$SUPPLY_CHAIN_FAIL_ON" && ! "$SUPPLY_CHAIN_FAIL_ON" =~ ^(INFO|LOW|MEDIUM|HIGH|CRITICAL)$ ]]; then
  echo "Invalid --supply-chain-fail-on: $SUPPLY_CHAIN_FAIL_ON (expected INFO, LOW, MEDIUM, HIGH or CRITICAL)" >&2
  exit 1
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

      # SBOM must run BEFORE resolver so the resolver can pick up
      # /app/.glog/sbom.cdx.json and upload it to /api/sca/resolver/sbom/.
      if [[ "$WITH_SBOM" == "true" ]]; then
        _HAS_SBOM=false
        for _l in "${LANGUAGES[@]}"; do [[ "$_l" == "sbom" ]] && _HAS_SBOM=true; done
        [[ "$_HAS_SBOM" == "false" ]] && LANGUAGES+=('sbom')
      fi

      # Resolver passes. When the platform (committed / native SARIF UI) needs a
      # different structure than the Glog server, the resolver runs twice:
      #   1. server format, with upload  -> what the server ingests
      #   2. platform format, no upload  -> what stays in .glog/ and gets committed
      for lang in "${LANGUAGES[@]}"; do
        [[ "$lang" == "resolver" ]] && continue
        echo "Analyzing language: $lang"
        scan_lang "$lang" "$SCAN_PATH" "$IGNORE" "$CLIENT" "$ENV" "$REGISTRY" "$SARIF_FORMAT_TYPE" "false" "$PRIVACY_TIER" "$GLOG_API_URL"
      done

      if [[ -n "$SERVER_SARIF_FORMAT_TYPE" && "$SERVER_SARIF_FORMAT_TYPE" != "$SARIF_FORMAT_TYPE" && "$RESOLVER_UPLOAD" == "true" ]]; then
        echo "Resolver pass 1/2: format=$SERVER_SARIF_FORMAT_TYPE (server upload)"
        scan_lang "resolver" "$SCAN_PATH" "$IGNORE" "$CLIENT" "$ENV" "$REGISTRY" "$SERVER_SARIF_FORMAT_TYPE" "true" "$PRIVACY_TIER" "$GLOG_API_URL"
        echo "Resolver pass 2/2: format=$SARIF_FORMAT_TYPE (local/platform artifact)"
        # This pass only rewrites the local platform artifact. Keep it fully
        # offline so it cannot duplicate or fail an already-completed upload.
        scan_lang "resolver" "$SCAN_PATH" "$IGNORE" "$CLIENT" "$ENV" "$REGISTRY" "$SARIF_FORMAT_TYPE" "false" "none" "$GLOG_API_URL"
      else
        echo "Resolver pass: format=$SARIF_FORMAT_TYPE upload=$RESOLVER_UPLOAD"
        scan_lang "resolver" "$SCAN_PATH" "$IGNORE" "$CLIENT" "$ENV" "$REGISTRY" "$SARIF_FORMAT_TYPE" "$RESOLVER_UPLOAD" "$PRIVACY_TIER" "$GLOG_API_URL"
      fi


       persist_scoped_scan_artifacts "$SCAN_PATH" "$PROJECT_PATH"
       verify_scan_artifacts "$PROJECT_PATH"

       if [[ "$REBUILD" == "true" ]]; then
          if [[ -z "$REBUILD_ARTIFACT" || -z "$REBUILD_PACKAGE" || -z "$REBUILD_VERSION" || -z "$REBUILD_ECOSYSTEM" ]]; then
            echo "Rebuild requires --rebuild-artifact, --rebuild-package, --rebuild-version and --rebuild-ecosystem" >&2
            exit 1
          fi
          if [[ -z "$GLOG_API_URL" || -z "$GLOG_TOKEN" ]]; then
            echo "Rebuild submission requires GLOG_API_URL and GLOG_TOKEN" >&2
            exit 1
          fi
          echo "Running reproducible-build worker on CI artifact"
          rebuild_args=(
            --api-url "$GLOG_API_URL" --token "$GLOG_TOKEN" --image "$REBUILD_IMAGE"
            --artifact "$REBUILD_ARTIFACT"
            --package-name "$REBUILD_PACKAGE" --package-version "$REBUILD_VERSION"
            --ecosystem "$REBUILD_ECOSYSTEM"
          )
          [[ -n "$REBUILD_MANIFEST" ]] && rebuild_args+=(--published-manifest "$REBUILD_MANIFEST")
         [[ -n "$SCL_UUID" ]] && rebuild_args+=(--source-code-location "$SCL_UUID")
         python3 "$ACTION_DIR/rebuild_client.py" "${rebuild_args[@]}"
       fi
       ;;
  esac
done
