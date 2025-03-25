#!/bin/bash

# Default list of languages

DEFAULT_LANGS=("cpp" "java" "javascript" "python" "kotlin" "php" "go" "ruby" "swift" "csharp" "oss" "php-stan" "git" "terraform" )

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
      go)                 languages["go"]=1 ;;
      rb)                 languages["ruby"]=1 ;;
      swift)              languages["swift"]=1 ;;
      cs)                 languages["csharp"]=1 ;;
      tf)                 languages["terraform"]=1 ;;
      git)                languages["git"]=1 ;;
      # Add more languages as needed
    esac
  done
  echo "${!languages[@]}"
}


# Function to scan language and path
scan_lang() {
    local lang=$1
    local path=$2
    local ignore=$3
    IMAGE_NAME="glog-scan-$lang"
    docker run --rm -e GLOGSERVICE="$GLOG_TOKEN" -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) -e IGNORE="$ignore" -v "$path":/app "ghcr.io/glogai/$IMAGE_NAME"
}

# Parse arguments

SCAN=false
LANGUAGES=()
IGNORE=""
PROJECT_PATH=$(pwd)
GLOG_TOKEN=$GLOG_TOKEN

while [[ $# -gt 0 ]]; do
    case $1 in
        scan)
            SCAN=true
            ;;
        --path)
            PROJECT_PATH="$2"
            shift  # Shift to get the value for --path
            ;;
        --lang)
            IFS=',' read -r -a LANGUAGES <<< "$2"
            shift  # Shift to get the value for --lang
            ;;
        --glogtoken)
            GLOG_TOKEN="$2"
            shift  # Shift to get the value for --glogtoken
            ;;
        --ignore)
            IGNORE="$2"
            shift  # Shift to get the value for --ignore
            ;;
        *)
            echo "Invalid option: $1"
            exit 1
            ;;
    esac
    shift  # Shift to the next argument
done



### Detect languages ###################################

if $SCAN; then
  # Detect the languages if --lang is not provided
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
        scan_lang "$lang" "$PROJECT_PATH" "$IGNORE"
    done
fi
