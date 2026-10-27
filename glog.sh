#!/bin/bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Image tags are derived, not authored. glog-tools/gbuild.sh names an image
# glog-scan-<lang>-<first 4 hex of md5("<lang>-<tool>" + SALT)> and writes the
# whole table to images.env, checked in beside this script and regenerated with
# `./gbuild.sh --env` in glog-tools. glog-tools' test_images_env suite fails if
# this copy drifts from the generator.
#
# The tags used to be written out here, in glog.ps1 and in glog-tools'
# gscan.sh. Three hand-kept copies of a derived value drift, and they did: after
# the C/C++ opengrep stage shipped, this script and glog.ps1 still named
# devskim's tag alone, so an Action scan of a C/C++ repo quietly skipped the
# stage every other driver ran.
IMAGES_ENV="$ACTION_DIR/images.env"
if [[ ! -f "$IMAGES_ENV" ]]; then
  echo "ERROR: $IMAGES_ENV is missing, so no image tag can be resolved." >&2
  echo "       It ships with this action; regenerate it from glog-tools with" >&2
  echo "       './gbuild.sh --env' if the checkout is incomplete." >&2
  exit 2
fi
# shellcheck source=images.env
source "$IMAGES_ENV"

DEFAULT_LANGS=("cpp" "java" "javascript" "python" "kotlin" "php" "ruby" "csharp" "oss" "terraform" "secrets" "resolver" "objectscript" "go") #"docker"

# Which stage runs for which language stays this driver's own decision - several
# languages have more than one engine built for them, and a few of those are not
# run here (gosec, phpstan, clair, and devskim for csharp and javascript). The
# tags, though, all come from images.env.
declare -A IMAGE_MAP=(
  [oss]="$GLOG_SCAN_IMAGE_OSS_DEPSCAN"
  [java]="$GLOG_SCAN_IMAGE_JAVA_SPOTBUGS $GLOG_SCAN_IMAGE_JAVA_OPENGREP"
  [ruby]="$GLOG_SCAN_IMAGE_RUBY_BRAKEMAN"
  [terraform]="$GLOG_SCAN_IMAGE_TERRAFORM_TERRAFORM $GLOG_SCAN_IMAGE_TERRAFORM_OPENGREP"
  [cpp]="$GLOG_SCAN_IMAGE_CPP_DEVSKIM"
  [python]="$GLOG_SCAN_IMAGE_PYTHON_BANDIT $GLOG_SCAN_IMAGE_PYTHON_OPENGREP"
  [secrets]="$GLOG_SCAN_IMAGE_SECRETS_GITLEAKS"
  [reachability]="$GLOG_SCAN_IMAGE_REACHABILITY_REACHABILITY"
  [csharp]="$GLOG_SCAN_IMAGE_CSHARP_OPENGREP"
  [php]="$GLOG_SCAN_IMAGE_PHP_DEVSKIM $GLOG_SCAN_IMAGE_PHP_OPENGREP"
  [kotlin]="$GLOG_SCAN_IMAGE_KOTLIN_SPOTBUGS"
  [resolver]="$GLOG_SCAN_IMAGE_RESOLVER_GLOG"
  [javascript]="$GLOG_SCAN_IMAGE_JAVASCRIPT_OPENGREP"
  #[docker]="$GLOG_SCAN_IMAGE_DOCKER_TRIVY"
  [objectscript]="$GLOG_SCAN_IMAGE_OBJECTSCRIPT_OPENGREP"
  [go]="$GLOG_SCAN_IMAGE_GO_OPENGREP"
  # CycloneDX SBOM generator (cdxgen). Writes /app/.glog/sbom.cdx.json which
  # the resolver (running after) uploads to /api/sca/resolver/sbom/.
  [sbom]="$GLOG_SCAN_IMAGE_SBOM_CDXGEN"
  # VEX: depscan over the source with the SBOM as input + reachability.
  # Writes /app/.glog/vex.cdx.json; uploaded after the resolver pass.
  [vex]="$GLOG_SCAN_IMAGE_OSS_DEPSCAN"
)

upload_vex() {
  local vex_file="$1/.glog/vex.cdx.json"
  if [[ ! -s "$vex_file" ]]; then
    echo "WARNING: VEX requested but $vex_file was not produced."
    return 0
  fi
  if [[ "$RESOLVER_UPLOAD" != "true" || "$PRIVACY_TIER" == "none" ]]; then
    echo "VEX kept locally: $vex_file"
    return 0
  fi
  local api="${GLOG_API_URL:-}"
  if [[ -z "$api" && -n "$CLIENT" ]]; then
    case "${ENV,,}" in
      dev|development) api="https://${CLIENT}.dev.glog.ai" ;;
      *) api="https://${CLIENT}.glog.ai" ;;
    esac
  fi
  if [[ -z "$api" || -z "${GLOG_TOKEN:-}" ]]; then
    echo "WARNING: VEX not uploaded (GLOG_API_URL / GLOG_TOKEN missing)."
    return 0
  fi
  local sbom_serial=""
  if [[ -s "$1/.glog/sbom.cdx.json" ]]; then
    sbom_serial=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("serialNumber",""))' "$1/.glog/sbom.cdx.json" 2>/dev/null || true)
  fi
  local code
  rm -f /tmp/glog-vex-upload.json
  code=$(curl -sS -o /tmp/glog-vex-upload.json -w '%{http_code}' -X POST \
    -H "Authorization: Token ${GLOG_TOKEN}" \
    -F "vex_file=@${vex_file};type=application/json" \
    -F "sbom_serial=${sbom_serial}" \
    -F "scl_uuid=${SCL_UUID:-}" \
    "${api%/}/api/sca/resolver/vex/" || true)
  code="${code:-000}"
  if [[ "$code" == "201" ]]; then
    echo "VEX uploaded: $(cat /tmp/glog-vex-upload.json)"
  else
    echo "WARNING: VEX upload failed (HTTP $code): $(head -c 300 /tmp/glog-vex-upload.json 2>/dev/null)"
  fi
}

# CBOM: cdxgen in crypto mode (inside the SBOM image) writes
# /app/.glog/cbom.cdx.json, then it is uploaded to /api/sca/resolver/cbom/.
# Best results need buildable source; for Java a prior build helps cdxgen
# resolve crypto API usage.
run_cbom() {
  local path="$1" registry="$2"
  local image="${registry}${GLOG_SCAN_IMAGE_SBOM_CDXGEN}"
  mkdir -p "$path/.glog"
  echo "Generating CBOM (cryptographic inventory)"
  # 1) generator in crypto mode (strongest for Java), 2) our source detector
  # merges certificates, keys, protocols and crypto API usage for all languages.
  # No FETCH_LICENSE override: the image enables license resolution
  # (Dockerfile.cdxgen) and turning it off leaves every CBOM component without
  # a license, the same fault the SBOM pass was fixed for.
  if ! docker run --rm --pull always -v "$path:/app" --entrypoint sh \
      -e CDXGEN_TIMEOUT_MS=600000 "$image" -c '
        rm -f /app/.glog/cbom.gen.json
        cdxgen --include-crypto --spec-version 1.6 -o /app/.glog/cbom.gen.json /app \
          || echo "WARNING: generator crypto pass failed; detector only."
        python3 /usr/local/glog/cbom_detector.py --src /app \
          --merge /app/.glog/cbom.gen.json --out /app/.glog/cbom.cdx.json
        rm -f /app/.glog/cbom.gen.json'; then
    echo "WARNING: CBOM generation failed; continuing."
  fi
}

upload_cbom() {
  local cbom_file="$1/.glog/cbom.cdx.json"
  if [[ ! -s "$cbom_file" ]]; then
    echo "WARNING: CBOM requested but $cbom_file was not produced."
    return 0
  fi
  if [[ "$RESOLVER_UPLOAD" != "true" || "$PRIVACY_TIER" == "none" ]]; then
    echo "CBOM kept locally: $cbom_file"
    return 0
  fi
  local api="${GLOG_API_URL:-}"
  if [[ -z "$api" && -n "$CLIENT" ]]; then
    case "${ENV,,}" in
      dev|development) api="https://${CLIENT}.dev.glog.ai" ;;
      *) api="https://${CLIENT}.glog.ai" ;;
    esac
  fi
  if [[ -z "$api" || -z "${GLOG_TOKEN:-}" ]]; then
    echo "WARNING: CBOM not uploaded (GLOG_API_URL / GLOG_TOKEN missing)."
    return 0
  fi
  local sbom_serial=""
  if [[ -s "$1/.glog/sbom.cdx.json" ]]; then
    sbom_serial=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("serialNumber",""))' "$1/.glog/sbom.cdx.json" 2>/dev/null || true)
  fi
  local code
  rm -f /tmp/glog-cbom-upload.json
  code=$(curl -sS -o /tmp/glog-cbom-upload.json -w '%{http_code}' -X POST \
    -H "Authorization: Token ${GLOG_TOKEN}" \
    -F "cbom_file=@${cbom_file};type=application/json" \
    -F "sbom_serial=${sbom_serial}" \
    -F "scl_uuid=${SCL_UUID:-}" \
    -F "profile=${GLOG_CBOM_PROFILE:-baseline}" \
    "${api%/}/api/sca/resolver/cbom/" || true)
  code="${code:-000}"
  if [[ "$code" == "201" ]]; then
    echo "CBOM uploaded: $(cat /tmp/glog-cbom-upload.json)"
  else
    echo "WARNING: CBOM upload failed (HTTP $code): $(head -c 300 /tmp/glog-cbom-upload.json 2>/dev/null)"
  fi
}

sbom_quality_gate() {
  # Optional CI gate: score the SBOM on the Glog server (nothing is stored)
  # and fail the run when the grade is below GLOG_SBOM_MIN_GRADE (A-F).
  local min="${GLOG_SBOM_MIN_GRADE:-}"
  [[ -z "$min" ]] && return 0
  local sbom_file="$1/.glog/sbom.cdx.json"
  if [[ ! -s "$sbom_file" ]]; then
    echo "WARNING: sbom-min-grade=$min set but $sbom_file was not produced; gate skipped."
    return 0
  fi
  local api="${GLOG_API_URL:-}"
  if [[ -z "$api" && -n "$CLIENT" ]]; then
    case "${ENV,,}" in
      dev|development) api="https://${CLIENT}.dev.glog.ai" ;;
      *) api="https://${CLIENT}.glog.ai" ;;
    esac
  fi
  if [[ -z "$api" || -z "${GLOG_TOKEN:-}" ]]; then
    echo "WARNING: SBOM quality gate skipped (GLOG_API_URL / GLOG_TOKEN missing)."
    return 0
  fi
  local code
  rm -f /tmp/glog-sbom-quality.json
  code=$(curl -sS -o /tmp/glog-sbom-quality.json -w '%{http_code}' -X POST \
    -H "Authorization: Token ${GLOG_TOKEN}" \
    -F "sbom_file=@${sbom_file};type=application/json" \
    -F "min_grade=${min}" \
    "${api%/}/api/sca/resolver/sbom-quality/" || true)
  code="${code:-000}"
  if [[ "$code" != "200" ]]; then
    echo "WARNING: SBOM quality gate could not run (HTTP $code): $(head -c 300 /tmp/glog-sbom-quality.json 2>/dev/null)"
    return 0
  fi
  local summary
  summary=$(python3 - /tmp/glog-sbom-quality.json <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(r.get("gate", "pass"), r.get("grade", "?"), r.get("score", "?"))
for c in r.get("categories", []):
    if c.get("applicable"):
        print(f"  {c['label']}: {c['score']} - {c['detail']}", file=sys.stderr)
for c in r.get("caps", []):
    print(f"  cap {c['max_grade']}: {c['reason']}", file=sys.stderr)
PY
)
  local gate grade score
  read -r gate grade score <<<"$summary"
  echo "SBOM quality: grade $grade (score $score), required $min or better."
  if [[ "$gate" == "fail" ]]; then
    echo "ERROR: SBOM quality grade $grade is below sbom-min-grade=$min." >&2
    SBOM_GATE_FAILED=true
  fi
}

# AI remediation (post-resolver triage + fix). Runs the glog-tools remediation
# image over the resolver's .glog/glog-scan.sarif, after the scan artifacts are
# final. It is the one stage that may write to the source tree, so it is opt-in
# and defaults to patch mode: the tree is left byte-identical and the accepted
# fixes land in .glog/glog-ai-remediation.patch. The image never pushes.
#
# Transport: with a scan token and no provider key the model calls go through
# the Glog server relay (<server>/api/remediation/llm), which picks the model
# and bills the tenant's AI budget, so a CI runner needs no provider key.
# Otherwise GLOG_LLM_BASE_URL / GLOG_LLM_MODEL / GLOG_LLM_API_KEY name an
# OpenAI-compatible endpoint directly. The OpenCode transport is gscan.sh only:
# it needs an OpenCode credential store on the host.
run_remediation() {
  local path="$1" registry="$2"
  local image_name="${GLOG_SCAN_IMAGE_REMEDIATION_REMEDIATION}"
  local run_image pull_args=()
  if [[ -n "${GLOG_IMAGE_REMEDIATION:-}" ]]; then
    run_image="$GLOG_IMAGE_REMEDIATION"
  else
    run_image="${registry}${image_name}"
    pull_args=(--pull always)
  fi
  if [[ ! -s "$path/.glog/glog-scan.sarif" ]]; then
    echo "WARNING: remediation skipped, $path/.glog/glog-scan.sarif was not produced." >&2
    return 0
  fi

  local transport="${GLOG_LLM_TRANSPORT:-}"
  if [[ -z "$transport" ]]; then
    if [[ -n "${GLOG_TOKEN:-}" && -z "${GLOG_LLM_API_KEY:-}" ]]; then
      transport=server
    else
      transport=direct
    fi
  fi
  local args=()
  case "$transport" in
    server)
      if [[ -z "${GLOG_TOKEN:-}" ]]; then
        echo "WARNING: remediation skipped, the server transport needs a scan token (--glogtoken)." >&2
        return 0
      fi
      # The relay lives on the same server the resolver uploads to, so it is
      # derived the same way unless --api-url or GLOG_LLM_SERVER_URL names it.
      local api="${GLOG_API_URL:-$(resolver_server_url)/api}"
      local relay_host
      relay_host=$(printf '%s' "${GLOG_LLM_SERVER_URL:-$api}" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##')
      if [[ "$relay_host" == *.localhost || "$relay_host" == "localhost" || "$relay_host" == "127.0.0.1" ]]; then
        # Same rule as gscan.sh: a local dev server binds loopback only, and on
        # the host network the image's OpenCode server is password-protected.
        args+=(--network host -e GLOG_REMEDIATION_HOST_NETWORK=true)
        [[ "$relay_host" != "127.0.0.1" ]] && args+=(--add-host "$relay_host:127.0.0.1")
      fi
      args+=(-e GLOG_LLM_TRANSPORT=server -e GLOG_API_URL="$api")
      [[ -n "${GLOG_LLM_SERVER_URL:-}" ]] && args+=(-e GLOG_LLM_SERVER_URL="$GLOG_LLM_SERVER_URL")
      ;;
    direct)
      if [[ -z "${GLOG_LLM_API_KEY:-}" || -z "${GLOG_LLM_BASE_URL:-}" ]]; then
        echo "WARNING: remediation skipped, it needs a scan token (server relay) or GLOG_LLM_BASE_URL and GLOG_LLM_API_KEY." >&2
        return 0
      fi
      # Bare -e: the key is copied from this shell's environment and never
      # appears in the docker argv.
      export GLOG_LLM_API_KEY
      args+=(-e GLOG_LLM_TRANSPORT=direct -e GLOG_LLM_API_KEY -e GLOG_LLM_BASE_URL="$GLOG_LLM_BASE_URL")
      ;;
    *)
      echo "WARNING: remediation skipped, transport '$transport' is not supported here (server or direct)." >&2
      return 0
      ;;
  esac
  [[ -n "${GLOG_LLM_MODEL:-}" ]] && args+=(-e GLOG_LLM_MODEL="$GLOG_LLM_MODEL")

  echo "AI remediation: mode=${GLOG_REMEDIATION_MODE:-patch} transport=$transport apply=${GLOG_REMEDIATION_APPLY:-true}"
  export GLOGSERVICE="${GLOG_TOKEN:-}"
  export GLOG_TOKEN
  if ! docker run "${pull_args[@]}" --rm \
      "${args[@]}" \
      -e GLOGSERVICE \
      -e GLOG_TOKEN \
      -e HOST_UID="$(id -u)" \
      -e HOST_GID="$(id -g)" \
      -e GLOG_IMAGE="$image_name" \
      -e HOST_PROJECT_PATH="$path" \
      -e GLOG_REMEDIATION_MODE="${GLOG_REMEDIATION_MODE:-patch}" \
      -e GLOG_REMEDIATION_APPLY="${GLOG_REMEDIATION_APPLY:-}" \
      -e GLOG_REMEDIATION_REQUIRE_VERIFIED="${GLOG_REMEDIATION_REQUIRE_VERIFIED:-}" \
      -e GLOG_REMEDIATION_ALLOW_DIRTY="${GLOG_REMEDIATION_ALLOW_DIRTY:-}" \
      -e GLOG_REMEDIATION_MIN_SEVERITY="${GLOG_REMEDIATION_MIN_SEVERITY:-}" \
      -e GLOG_REMEDIATION_MAX_FINDINGS="${GLOG_REMEDIATION_MAX_FINDINGS:-}" \
      -e GLOG_REMEDIATION_CHUNK_SIZE="${GLOG_REMEDIATION_CHUNK_SIZE:-}" \
      -e GLOG_REMEDIATION_SALVAGE_PARTIAL="${GLOG_REMEDIATION_SALVAGE_PARTIAL:-}" \
      -e GLOG_REMEDIATION_RETRY_ON_REVERT="${GLOG_REMEDIATION_RETRY_ON_REVERT:-}" \
      -v "$path":/app \
      "$run_image"; then
    echo "WARNING: AI remediation failed; see $path/.glog/glog-ai-remediation-report.md. Scan results are unaffected." >&2
    return 0
  fi
  if [[ -s "$path/.glog/glog-ai-remediation.patch" ]]; then
    echo "AI remediation patch: $path/.glog/glog-ai-remediation.patch (review, then git apply)"
  fi
  echo "AI remediation report: $path/.glog/glog-ai-remediation-report.md"
}

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
  --cbom                    Generate a CycloneDX CBOM (cryptographic inventory) and upload it.
  --sbom-min-grade <A-F>    Fail (exit 3) when the SBOM quality grade is worse than this (implies --sbom).
  --vex                     Generate a VEX with depscan + reachability (implies --sbom).
                            Install dependencies first (npm ci, venv in the repo, mvn
                            dependency:resolve, ...) or most results stay in_triage.
  --scl-uuid UUID           Source Code Location UUID to bind SARIF/SBOM uploads to
  --privacy-tier TIER       full (default) | metrics | none. Controls what leaves the tenant.
  --mock-resolver           Serve AI answers from the server-side OpenAI mock (no OpenAI cost;
                            simulated latency and Tier 5 rate limits). Testing only.
  --api-url URL             Server URL for the host-side uploads (VEX, rebuild). The resolver
                            derives its own URL from --client/--env (dev -> <client>.dev.glog.ai,
                            localhost -> http://<client>.localhost:8000), so with --upload the
                            two must agree or the scan is refused.
  --fail-on-upload-error    Exit 2 when the resolver reports UPLOAD_FAILED (default: warn only)
  --supply-chain             Run the bounded supply-chain scan
  --supply-chain-policy FILE  Enable scanning with a policy file relative to --path
  --supply-chain-offline      Disable registry network access; use only the persistent cache
  --supply-chain-cache-only   Use only the persistent metadata cache
  --supply-chain-fail-on LEVEL  Policy severity threshold: INFO, LOW, MEDIUM, HIGH or CRITICAL
   --supply-chain-format FORMAT  Output: json, sarif or both (default: both)
   --rebuild                    Discover all lockfile dependencies and run the worker for each
   --rebuild-artifact PATH      Optional single package artifact
   --rebuild-manifest PATH      Optional published manifest for single-artifact mode
   --rebuild-package NAME       Package name for single-artifact mode
   --rebuild-version VERSION    Package version for single-artifact mode
   --rebuild-ecosystem NAME     npm, pypi, go, cargo, maven or rubygems (single-artifact mode)
   --rebuild-image IMAGE        Rebuild worker image
   --max-packages N             Cap dependencies verified in all-dependency rebuild mode
  --remediate               After the scan, triage the findings again and fix them with the
                            AI remediation image. Default patch mode leaves the tree untouched
                            and writes .glog/glog-ai-remediation.patch
  --remediation-mode MODE   patch (default), branch (commit on glog/remediation/..., never
                            pushed) or local (uncommitted edits). Implies --remediate
  --remediate-branch        Shorthand for --remediation-mode branch
  --remediate-local         Shorthand for --remediation-mode local
  --remediate-dry-run       Triage only: no edits, no patch
  --remediate-min-severity S  Severity floor: LOW (default), MEDIUM, HIGH or CRITICAL
  --remediate-max-findings N  Cap the findings handed to the fix agent, highest severity first
  --require-verified        Accept a fix only when the project's own build/test/lint passed
  --allow-dirty             Let branch/local mode run on a tree with uncommitted changes


EOF
}

cleanup() {
  if [[ -n "${TEMP_SCAN_DIR:-}" && -d "${TEMP_SCAN_DIR:-}" ]]; then
    rm -rf "$TEMP_SCAN_DIR"
  fi
  [[ -n "${SCAN_START_STAMP:-}" ]] && rm -f "$SCAN_START_STAMP"
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

# Resolve every image this scan is about to run, before it runs any of them.
#
# `docker run` reports a tag that is not in the registry as a "manifest unknown"
# line inside its own output, and the scan then carries on and finishes with no
# findings for that language - which reads exactly like a clean repo. Asking the
# registry first turns that into a failure that names the tag and says what to
# do about it.
#
# A language whose GLOG_IMAGE_<LANG> override is set is skipped: an override may
# name a local image that was never pushed anywhere, so there is nothing to ask
# the registry about. GLOG_SKIP_IMAGE_VERIFY=true skips the whole check, for an
# air-gapped or offline run where the registry cannot be reached.
verify_images() {
  local registry="$1"; shift
  local lang image_var image ref err
  local missing=() warned=0

  if [[ "${GLOG_SKIP_IMAGE_VERIFY:-false}" == "true" ]]; then
    echo "Image verification skipped (GLOG_SKIP_IMAGE_VERIFY=true)."
    return 0
  fi
  if ! command -v docker > /dev/null 2>&1; then
    echo "WARNING: docker not on PATH, skipping image verification." >&2
    return 0
  fi

  for lang in "$@"; do
    [[ -z "${IMAGE_MAP[$lang]:-}" ]] && continue
    image_var="GLOG_IMAGE_$(printf '%s' "$lang" | tr '[:lower:]-' '[:upper:]_')"
    if [[ -n "${!image_var:-}" ]]; then
      echo "Image check: $lang uses the local override ${image_var}."
      continue
    fi
    for image in ${IMAGE_MAP[$lang]}; do
      ref="${registry}${image}"
      if ! err="$(docker manifest inspect "$ref" 2>&1 > /dev/null)"; then
        # Only a registry saying the manifest is not there is worth failing a
        # scan over. A timeout, a 429 or a missing credential is a fact about
        # the network, not about the tag, and the pull that follows may well
        # succeed - so it is a warning.
        if [[ "$err" == *"manifest unknown"* || "$err" == *"not found"* \
              || "$err" == *"name unknown"* || "$err" == *"no such manifest"* ]]; then
          missing+=("$lang: $ref")
        else
          warned=$((warned + 1))
          echo "WARNING: could not verify $ref (${err//$'\n'/ }); continuing." >&2
        fi
      fi
    done
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "ERROR: these images could not be resolved in ${registry}:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo "       Each tag is derived from glog-tools/gbuild.sh; see the header of" >&2
    echo "       images.env. Either the stage was never built and pushed, or" >&2
    echo "       images.env has drifted from the build script - regenerate it with" >&2
    echo "       './gbuild.sh --env' in glog-tools. A local image can be used" >&2
    echo "       instead by setting GLOG_IMAGE_<LANG>; set GLOG_SKIP_IMAGE_VERIFY=true" >&2
    echo "       to run offline." >&2
    return 1
  fi

  if [[ "$warned" -gt 0 ]]; then
    echo "Image check: the rest resolve in ${registry} ($warned unverified)."
  else
    echo "Image check: all mapped images resolve in ${registry}."
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
  local resolver_upload=$8
  local privacy_tier=${9:-full}
  local api_url=${10:-}

  local image_list="${IMAGE_MAP[$lang]:-}"
  if [[ -z "$image_list" ]]; then
    echo "  (skipping '$lang': no scanner image mapped — use --sbom / --inventory flags, not --lang)"
    return 0
  fi

  # Local image override for one language, named GLOG_IMAGE_<LANG> with the
  # language upper-cased and '-' folded to '_' (GLOG_IMAGE_RESOLVER=...). Same
  # convention as gscan.sh, which documents how to build the overlay: cheaper
  # than retagging a published image, which replaces what a plain scan runs.
  local image_override_var="GLOG_IMAGE_$(printf '%s' "$lang" | tr '[:lower:]-' '[:upper:]_')"
  local image_override="${!image_override_var:-}"
  if [[ -n "$image_override" ]]; then
    image_list="$image_override"
  fi

  for image_name in $image_list; do
    if [[ -n "${GLOG_DEPSCAN_VDB_VOLUME:-}" ]]; then
      if ! docker volume inspect "${GLOG_DEPSCAN_VDB_VOLUME}" > /dev/null 2>&1; then
        echo "Creating Docker volume: ${GLOG_DEPSCAN_VDB_VOLUME}"
        docker volume create "${GLOG_DEPSCAN_VDB_VOLUME}"
      fi
    fi

    EXTRA_ARGS=()
    # A local dev server (GLOG_API_URL=http://test.localhost:8000) binds
    # 127.0.0.1 only and its *.localhost name does not resolve inside a
    # container, so join the host network and pin the name to loopback.
    # The resolver ignores GLOG_API_URL and derives the host from CLIENT/ENV:
    # --env localhost means http://<client>.localhost:8000/api/.
    local api_host=""
    if [[ "${env,,}" == "localhost" && -n "$client" ]]; then
      api_host="$client.localhost"
    elif [[ -n "$api_url" ]]; then
      api_host=$(printf '%s' "$api_url" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##')
    fi
    local host_network="false"
    if [[ "$api_host" == *.localhost || "$api_host" == "localhost" ]]; then
      EXTRA_ARGS+=(--network host --add-host "$api_host:127.0.0.1")
      host_network="true"
    fi

    if [[ "$image_name" == "${GLOG_SCAN_IMAGE_SBOM_CDXGEN}"* ]]; then
      # SBOM (cdxgen + mvnw) needs network egress to Maven Central / npm registry
      # and a persistent Maven cache to avoid re-downloading plugins each run.
      [[ "$host_network" == "true" ]] || EXTRA_ARGS+=(--network host)
      mkdir -p "${HOME}/.glog-m2"
      EXTRA_ARGS+=(-v "${HOME}/.glog-m2:/root/.m2")
      EXTRA_ARGS+=(-e CDXGEN_TIMEOUT_MS=600000)
      # No FETCH_LICENSE override: the image enables license resolution
      # (Dockerfile.cdxgen) and turning it off leaves every component of the
      # report without a license.
    fi

    if [[ "$lang" == "vex" ]]; then
      EXTRA_ARGS+=(-e GLOG_VEX=true)
      EXTRA_ARGS+=(-e GLOG_VEX_REACHABILITY="${GLOG_VEX_REACHABILITY:-true}")
    fi

    # Override the VEX builder baked into the oss image with a local copy: the
    # VEX logic changes far more often than the image, so this avoids rebuilding
    # and pushing a multi-GB scanner image for every change to vex_builder.py.
    if [[ "$image_name" == "${GLOG_SCAN_IMAGE_OSS_DEPSCAN}"* && -n "${GLOG_VEX_BUILDER:-}" ]]; then
      [[ -f "$GLOG_VEX_BUILDER" ]] || { echo "ERROR: GLOG_VEX_BUILDER=$GLOG_VEX_BUILDER not found" >&2; exit 1; }
      EXTRA_ARGS+=(-v "${GLOG_VEX_BUILDER}:/usr/local/glog/vex_builder.py:ro")
    fi

    # A local override is used verbatim: no registry prefix and no pull, because
    # a local image is local. gscan.sh applies the same rule (see its
    # image_override / resolve_image_ref), and a scan run through either script
    # has to resolve the override to the same reference.
    local run_image pull_args=()
    if [[ -n "$image_override" ]]; then
      run_image="$image_name"
    else
      run_image="${registry}${image_name}"
      pull_args=(--pull always)
    fi

    # Host-side depscan VDB cache (baked baseline + incremental refresh).
    # A named volume (GLOG_DEPSCAN_VDB_VOLUME) takes precedence.
    if [[ "$image_name" == "${GLOG_SCAN_IMAGE_OSS_DEPSCAN}"* && -z "${GLOG_DEPSCAN_VDB_VOLUME:-}" \
          && "${GLOG_VDB_CACHE:-true}" == "true" ]]; then
      local vdb_dir="${GLOG_VDB_CACHE_DIR:-${HOME}/.glog-vdb}"
      mkdir -p "$vdb_dir"
      if [[ -z "$(ls -A "$vdb_dir" 2>/dev/null)" ]]; then
        echo "Seeding depscan VDB cache at $vdb_dir from image baseline..."
        docker pull -q "$run_image" > /dev/null || true
        # Mount the host dir at /seed (not /vdb) so the baked /vdb stays visible.
        docker run --rm --entrypoint sh -v "$vdb_dir":/seed "$run_image" \
          -c 'cp -a /vdb/. /seed/ 2>/dev/null; chown -R '"$(id -u):$(id -g)"' /seed' \
          || echo "WARNING: VDB seed failed; depscan will download the DB."
      else
        echo "Using cached depscan VDB at $vdb_dir ($(du -sh "$vdb_dir" 2>/dev/null | cut -f1))"
      fi
      EXTRA_ARGS+=(-v "$vdb_dir":/vdb -e VDB_HOME=/vdb -e VDB_AGE_HOURS="${VDB_AGE_HOURS:-168}")
    fi

    # Host-side local-model switches (recall plan D0) are deliberately absent
    # from this block: the model runs as a host pre-step inside gscan.sh,
    # before any container, and never from inside one. Forwarding any
    # GLOG_LOCAL_* knob here would hand a workflow variable to the container
    # without that pre-step having resolved it.
    # `-e NAME` with no `=value` is read by the docker CLI from THIS shell's
    # environment, so the token stays out of the command line - which every
    # user on the host (and every step of the job, via `ps`) can read for as
    # long as the scan runs.
    export GLOGSERVICE="${GLOG_TOKEN}"
    export GLOG_TOKEN
    docker run "${pull_args[@]}" --rm \
      "${EXTRA_ARGS[@]}" \
      -e GLOGSERVICE \
      -e GLOG_TOKEN \
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
      -e GLOG_DEDUP_STATEMENT_SCOPE_ELEMENT_SPLIT="${GLOG_DEDUP_STATEMENT_SCOPE_ELEMENT_SPLIT:-false}" \
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
WITH_VEX=false
WITH_CBOM=false
SBOM_GATE_FAILED=false
SBOM_ONLY=false
SCL_UUID=""
FORCE_INVENTORY=false
PRIVACY_TIER="${PRIVACY_TIER:-full}"
MOCK_RESOLVER="${MOCK_RESOLVER:-false}"
FAIL_ON_UPLOAD_ERROR="${FAIL_ON_UPLOAD_ERROR:-false}"
UPLOAD_FAILED=false
# Touched when a scan starts; .glog/glog-scan.log is trusted only if newer.
SCAN_START_STAMP="$(mktemp -t glog-scan-start.XXXXXX)"
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
REBUILD_IMAGE="${REBUILD_IMAGE:-ghcr.io/glogai/${GLOG_SCAN_IMAGE_REBUILD_REBUILD}}"
# Bounded all-dependency mode: every package is downloaded and hashed, so an
# unbounded run would make the scan far too slow on large lockfiles.
REBUILD_MAX_PACKAGES="${REBUILD_MAX_PACKAGES:-}"
REMEDIATE="${REMEDIATE:-false}"
GLOG_REMEDIATION_MODE="${GLOG_REMEDIATION_MODE:-patch}"
GLOG_REMEDIATION_APPLY="${GLOG_REMEDIATION_APPLY:-}"
GLOG_REMEDIATION_REQUIRE_VERIFIED="${GLOG_REMEDIATION_REQUIRE_VERIFIED:-}"
GLOG_REMEDIATION_ALLOW_DIRTY="${GLOG_REMEDIATION_ALLOW_DIRTY:-}"
GLOG_REMEDIATION_MIN_SEVERITY="${GLOG_REMEDIATION_MIN_SEVERITY:-}"
GLOG_REMEDIATION_MAX_FINDINGS="${GLOG_REMEDIATION_MAX_FINDINGS:-}"


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
    --cbom) WITH_CBOM=true; shift ;;
    --sbom-min-grade) GLOG_SBOM_MIN_GRADE="$2"; WITH_SBOM=true; shift 2 ;;
    --vex) WITH_VEX=true; WITH_SBOM=true; shift ;;
    --sbom-only) SBOM_ONLY=true; WITH_SBOM=true; shift ;;
    --scl-uuid) SCL_UUID="$2"; shift 2 ;;
    --privacy-tier) PRIVACY_TIER="$2"; shift 2 ;;
    --mock-resolver) MOCK_RESOLVER=true; shift ;;
    --fail-on-upload-error) FAIL_ON_UPLOAD_ERROR=true; shift ;;
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
     --max-packages|--rebuild-max-packages) REBUILD_MAX_PACKAGES="$2"; shift 2 ;;
    --remediate) REMEDIATE=true; shift ;;
    --remediation-mode) GLOG_REMEDIATION_MODE="$2"; REMEDIATE=true; shift 2 ;;
    --remediate-branch) GLOG_REMEDIATION_MODE=branch; REMEDIATE=true; shift ;;
    --remediate-local) GLOG_REMEDIATION_MODE=local; REMEDIATE=true; shift ;;
    --remediate-dry-run) GLOG_REMEDIATION_APPLY=false; REMEDIATE=true; shift ;;
    --remediate-min-severity) GLOG_REMEDIATION_MIN_SEVERITY="$2"; REMEDIATE=true; shift 2 ;;
    --remediate-max-findings) GLOG_REMEDIATION_MAX_FINDINGS="$2"; REMEDIATE=true; shift 2 ;;
    --require-verified) GLOG_REMEDIATION_REQUIRE_VERIFIED=true; shift ;;
    --allow-dirty) GLOG_REMEDIATION_ALLOW_DIRTY=true; shift ;;
     -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

case "$PRIVACY_TIER" in
  full|metrics|none) ;;
  *) echo "Invalid --privacy-tier: $PRIVACY_TIER (expected: full, metrics, none)"; exit 1 ;;
esac

# The resolver (GlogService.buildBaseUrl) ignores GLOG_API_URL and derives the
# server from CLIENT/ENV. An --api-url that names a different host would send
# the host-side uploads to one server and the resolver's findings to another
# (a 2026-10-07 benchmark run with --env dev went to the remote dev tenant
# while --api-url pointed at localhost), so refuse that combination up front.
resolver_server_url() {
  local client="${CLIENT:-test}" env="${ENV,,}"
  if [[ -z "$env" ]]; then echo "https://$client.glog.ai"
  elif [[ "$env" == "localhost" ]]; then echo "http://$client.localhost:8000"
  else echo "https://$client.$env.glog.ai"
  fi
}
if [[ -n "$GLOG_API_URL" && "$RESOLVER_UPLOAD" == "true" ]]; then
  _api_norm="${GLOG_API_URL%/}"; _api_norm="${_api_norm%/api}"
  if [[ "$_api_norm" != "$(resolver_server_url)" ]]; then
    echo "ERROR: --api-url is $GLOG_API_URL but the resolver will upload to $(resolver_server_url) (derived from --client/--env)." >&2
    echo "       For a local server pass --env localhost; for a hosted tenant drop --api-url or make it match." >&2
    exit 1
  fi
fi

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

case "$GLOG_REMEDIATION_MODE" in
  patch|branch|local) ;;
  *) echo "Invalid --remediation-mode: $GLOG_REMEDIATION_MODE (expected: patch, branch, local)" >&2; exit 1 ;;
esac

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
      touch "$SCAN_START_STAMP"

      if [[ ${#FILES[@]} -gt 0 ]]; then
        echo "Preparing scoped scan for selected files..."
        SCAN_PATH="$(prepare_scoped_files_dir "$PROJECT_PATH" "${FILES[@]}")"
        echo "Scoped scan directory: $SCAN_PATH"
      fi

      if [[ ${#LANGUAGES[@]} -eq 0 ]]; then
        # shellcheck disable=SC2207
        LANGUAGES=($(detect_languages "$SCAN_PATH"))
      fi

      # Reachability is not a language, it is the CPG/dataflow engine that runs
      # over Python sources. detect_languages maps file EXTENSIONS to scanner
      # keys, so nothing it returns could ever select it. Chosen here, after
      # LANGUAGES is populated, so it applies however Python was selected: by
      # detection or by an explicit -l python. A scan with no Python is
      # untouched, and -l reachability on its own still works as before.
      if [[ " ${LANGUAGES[*]} " == *" python "* && " ${LANGUAGES[*]} " != *" reachability "* ]]; then
        LANGUAGES+=('reachability')
      fi

      # SBOM must run BEFORE resolver so the resolver can pick up
      # /app/.glog/sbom.cdx.json and upload it to /api/sca/resolver/sbom/.
      if [[ "$WITH_SBOM" == "true" ]]; then
        _HAS_SBOM=false
        for _l in "${LANGUAGES[@]}"; do [[ "$_l" == "sbom" ]] && _HAS_SBOM=true; done
        [[ "$_HAS_SBOM" == "false" ]] && LANGUAGES+=('sbom')
      fi
      # VEX needs the SBOM of this run, so it is queued after it.
      if [[ "$WITH_VEX" == "true" ]]; then
        LANGUAGES+=('vex')
      fi

      # Every image this run will use, resolved before the first container
      # starts. Here rather than earlier because LANGUAGES is only final now.
      if [[ "$REMEDIATE" == "true" && -z "${GLOG_IMAGE_REMEDIATION:-}" ]]; then
        IMAGE_MAP[remediation]="$GLOG_SCAN_IMAGE_REMEDIATION_REMEDIATION"
        verify_images "$REGISTRY" "${LANGUAGES[@]}" remediation
      else
        verify_images "$REGISTRY" "${LANGUAGES[@]}"
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

      if [[ "$WITH_VEX" == "true" ]]; then
        upload_vex "$SCAN_PATH"
      fi
      if [[ "$WITH_CBOM" == "true" ]]; then
        run_cbom "$SCAN_PATH" "$REGISTRY"
        upload_cbom "$SCAN_PATH"
      fi
      if [[ "$WITH_SBOM" == "true" ]]; then
        sbom_quality_gate "$SCAN_PATH"
      fi

      # The resolver container exits 0 even when its uploads failed (entrypoint.py
      # discards the jar's exit code), so the only signal is the UPLOAD_FAILED line
      # it writes to .glog/glog-scan.log. Only a log written by this run counts:
      # glog.sh does not empty .glog/ first, so an older log must not trip it.
      if [[ "$RESOLVER_UPLOAD" == "true" ]]; then
        _rlog="$SCAN_PATH/.glog/glog-scan.log"
        if [[ -f "$_rlog" && "$_rlog" -nt "$SCAN_START_STAMP" ]] && grep -q 'UPLOAD_FAILED' "$_rlog"; then
          UPLOAD_FAILED=true
          echo "ERROR: resolver upload failed: $(grep -m1 -oE 'UPLOAD_FAILED[^|]*(\| details=\[[^]]{0,200})?' "$_rlog")" >&2
        fi
      fi

       persist_scoped_scan_artifacts "$SCAN_PATH" "$PROJECT_PATH"
       verify_scan_artifacts "$PROJECT_PATH"
       # On the real tree, not a scoped copy: the fixes have to land where the
       # developer will apply them, and the persisted SARIF is there too.
       if [[ "$REMEDIATE" == "true" ]]; then
         run_remediation "$PROJECT_PATH" "$REGISTRY"
       fi
       if [[ "$SBOM_GATE_FAILED" == "true" ]]; then
         echo "Exiting 3 because the SBOM quality gate failed (artifacts were still written to .glog/)." >&2
         exit 3
       fi
       if [[ "$UPLOAD_FAILED" == "true" && "$FAIL_ON_UPLOAD_ERROR" == "true" ]]; then
         echo "Exiting 2 because --fail-on-upload-error is set (SARIF was still written to .glog/)." >&2
         exit 2
       fi

        if [[ "$REBUILD" == "true" ]]; then
           if [[ -z "$GLOG_API_URL" && -n "$CLIENT" ]]; then
             # The resolver image carries its own server URL; the host-side rebuild
             # client does not, so derive the tenant URL from client and env.
             case "${ENV,,}" in
               dev|development) GLOG_API_URL="https://${CLIENT}.dev.glog.ai" ;;
               *) GLOG_API_URL="https://${CLIENT}.glog.ai" ;;
             esac
             echo "Rebuild: --api-url not set, using $GLOG_API_URL"
           fi
           if [[ -z "$GLOG_API_URL" || -z "$GLOG_TOKEN" ]]; then
             echo "Warning: rebuild skipped, it requires GLOG_API_URL (--api-url) and GLOG_TOKEN" >&2
           else
           echo "Running reproducible-build worker for all discovered dependencies"
           rebuild_args=(
             --api-url "$GLOG_API_URL" --token "$GLOG_TOKEN" --image "$REBUILD_IMAGE"
             --project-path "$PROJECT_PATH"
           )
           [[ -n "$SCL_UUID" ]] && rebuild_args+=(--source-code-location "$SCL_UUID")
           # By default this is all-dependency mode. The legacy flags opt into one artifact.
           if [[ -n "$REBUILD_ARTIFACT" ]]; then
             if [[ -z "$REBUILD_PACKAGE" || -z "$REBUILD_VERSION" || -z "$REBUILD_ECOSYSTEM" ]]; then
               echo "Single-artifact mode requires --rebuild-package, --rebuild-version and --rebuild-ecosystem" >&2
               exit 1
             fi
             rebuild_args+=(--artifact "$REBUILD_ARTIFACT" --package-name "$REBUILD_PACKAGE"
               --package-version "$REBUILD_VERSION" --ecosystem "$REBUILD_ECOSYSTEM")
             [[ -n "$REBUILD_MANIFEST" ]] && rebuild_args+=(--published-manifest "$REBUILD_MANIFEST")
           else
             rebuild_args+=(--auto)
             [[ -n "$REBUILD_MAX_PACKAGES" ]] && rebuild_args+=(--max-packages "$REBUILD_MAX_PACKAGES")
           fi
           python3 "$ACTION_DIR/rebuild_client.py" "${rebuild_args[@]}" \
             || echo "Warning: rebuild submission failed; SARIF/SBOM results are unaffected" >&2
           fi
        fi
       ;;
  esac
done
