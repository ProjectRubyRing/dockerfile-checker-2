#!/usr/bin/env bash
# Static checker for Dockerfile, build context resources, entrypoint scripts,
# WildFly jboss-cli CLI files, and UBI 9.6 runtime consistency.

set -o pipefail

VERSION="0.1.0"

CONTEXT_DIR="."
DOCKERFILE_PATH=""
ENTRYPOINT_OVERRIDE=""
FAIL_ON="error"
INCLUDE_UNUSED_ALL=0
NO_COLOR=0
PROGRESS=1
REPORT_ENABLED=1
REPORT_FILE=""
MERMAID_ENABLED=1
MERMAID_FILE=""
ASCII_ART_ENABLED=1
ASCII_ART_FILE=""
VAR_REPORT_ENABLED=1
VAR_REPORT_FILE=""
SOFTWARE_REPORT_ENABLED=1
SOFTWARE_REPORT_FILE=""
CONFIG_REPORT_ENABLED=1
CONFIG_REPORT_FILE=""
ECS_ENV_REPORT_ENABLED=1
ECS_ENV_REPORT_FILE=""
CONTAINER_CHECK_REPORT_ENABLED=1
CONTAINER_CHECK_REPORT_FILE=""
RUNTIME_PROBE_ENABLED=0
RUNTIME_PROBE_IMAGE=""
RUNTIME_PROBE_KEEP_IMAGE=0
RUNTIME_PROBE_IMAGE_CUSTOM=0
RUNTIME_PROBE_EFFECTIVE_IMAGE=""
declare -a RUNTIME_PROBE_BUILD_OPTIONS=()
EAP_STARTUP_PROBE_ENABLED=0
EAP_STARTUP_TARGET="build"
EAP_STARTUP_IMAGE=""
EAP_STARTUP_IMAGE_CUSTOM=0
EAP_STARTUP_RUN_IMAGE=""
EAP_STARTUP_KEEP_IMAGE=0
EAP_STARTUP_CONTAINER=""
EAP_STARTUP_CONTAINER_CUSTOM=0
EAP_STARTUP_KEEP_CONTAINER=0
EAP_STARTUP_TIMEOUT=180
EAP_STARTUP_COMMAND=""
EAP_STARTUP_EFFECTIVE_IMAGE=""
EAP_STARTUP_EFFECTIVE_CONTAINER=""
EAP_STARTUP_EFFECTIVE_MODE=""
declare -a EAP_STARTUP_BUILD_OPTIONS=()
declare -a EAP_STARTUP_RUN_OPTIONS=()
DOCKER_USE_SUDO=0
DOCKER_CAPTURE_OUTPUT=""
DOCKER_CAPTURE_RC=0
DOCKER_CAPTURE_PERMISSION=0
DOCKER_CAPTURE_SUDO_ATTEMPTED=0
DOCKER_CAPTURE_SUDO_FAILED=0

declare -a F_SEV=()
declare -a F_PHASE=()
declare -a F_FILE=()
declare -a F_LINE=()
declare -a F_CODE=()
declare -a F_MSG=()
declare -A F_COUNT=([ERROR]=0 [WARN]=0 [INFO]=0)

declare -a DF_INSTR=()
declare -a DF_BODY=()
declare -a DF_START=()
declare -a DF_END=()
declare -a DF_STAGE=()

declare -a STAGE_NAME=()
declare -a STAGE_BASE=()
declare -a STAGE_LINE=()
declare -a STAGE_WORKDIR_FINAL=()
declare -A STAGE_BY_NAME=()

declare -A DOCKER_ENV=()
declare -A DOCKER_ENV_LINE=()
declare -A DOCKER_ARG=()
declare -A DOCKER_ARG_LINE=()
declare -A DOCKER_VAR_USED=()

declare -A DOCKERIGNORE_PATTERNS=()
declare -a DOCKERIGNORE_ORDER=()
declare -A REFERENCED_CONTEXT=()
declare -A CONTEXT_SYMLINK_SEEN=()
declare -A CONTAINER_TO_CONTEXT=()
declare -A SHELL_FILES=()
declare -A SHELL_REASON=()
declare -A CLI_FILES=()
declare -A CLI_REASON=()
declare -A CLI_JNDI_SEEN=()
declare -A MISSING_PATH_SEEN=()

declare -a REL_FROM=()
declare -a REL_TO=()
declare -a REL_LABEL=()
declare -a REL_PHASE=()
declare -a REL_FILE=()
declare -a REL_LINE=()
declare -A REL_SEEN=()

declare -a VAR_NAME=()
declare -a VAR_CATEGORY=()
declare -a VAR_ACTION=()
declare -a VAR_FILE=()
declare -a VAR_LINE=()
declare -a VAR_VALUE=()
declare -a VAR_PHASE=()
declare -a VAR_NOTE=()

declare -a SW_NAME=()
declare -a SW_TYPE=()
declare -a SW_VERSION=()
declare -a SW_SOURCE=()
declare -a SW_PHASE=()
declare -a SW_FILE=()
declare -a SW_LINE=()
declare -a SW_EVIDENCE=()
declare -a SW_NOTE=()
declare -A SW_SEEN=()

declare -a CFG_DOMAIN=()
declare -a CFG_COMPONENT=()
declare -a CFG_SETTING=()
declare -a CFG_DESCRIPTION=()
declare -a CFG_VALUE=()
declare -a CFG_RECOMMENDED=()
declare -a CFG_DISTANCE=()
declare -a CFG_SEVERITY=()
declare -a CFG_PHASE=()
declare -a CFG_FILE=()
declare -a CFG_LINE=()
declare -a CFG_EVIDENCE=()
declare -A CFG_SEEN=()

declare -a ECS_ENV_NAME=()
declare -a ECS_ENV_REQUIREMENT=()
declare -a ECS_ENV_SOURCE=()
declare -a ECS_ENV_FILE=()
declare -a ECS_ENV_LINE=()
declare -a ECS_ENV_CURRENT_VALUE=()
declare -a ECS_ENV_DEFAULT_VALUE=()
declare -a ECS_ENV_TASKDEF_FIELD=()
declare -a ECS_ENV_REASON=()
declare -a ECS_ENV_EVIDENCE=()
declare -A ECS_ENV_SEEN=()

FINAL_STAGE=-1
FINAL_BASE=""
FINAL_WORKDIR="/"
FINAL_USER=""
FINAL_USER_LINE=0
FINAL_ENTRYPOINT_BODY=""
FINAL_ENTRYPOINT_LINE=0
FINAL_CMD_BODY=""
FINAL_CMD_LINE=0
FINAL_IS_UBI9=0
FINAL_IS_UBI96=0
FINAL_IS_UBI_MINIMAL=0
FINAL_INSTALLS_BASH=0
FINAL_INSTALLS_KSH=0
FINAL_INSTALLS_JAVA=0
FINAL_NEEDS_KSH=0
FINAL_NEEDS_JAVA=0
FINAL_DOCKERFILE_SHELL_KSH=0

usage() {
  cat <<'USAGE'
docker-context-checker.sh - Dockerfile / build context static checker

Usage:
  ./docker-context-checker.sh [options]

Options:
  -c, --context DIR        Build context directory. Default: current directory.
  -f, --dockerfile FILE    Dockerfile path. Default: <context>/Dockerfile.
  -e, --entrypoint FILE    Entrypoint shell file in the build context to scan
                           when it cannot be resolved from Dockerfile.
  -o, --output FILE        Write Excel-importable UTF-8 BOM CSV report.
                           Default: ./docker-context-checker-results.csv.
      --mermaid FILE       Write build-context relationship diagram as Mermaid.
                           Default: ./docker-context-relations.mmd.
      --ascii-art FILE     Write build-context relationship diagram as aligned
                           ASCII art. Default: ./docker-context-relations.txt.
      --variables-output FILE
                           Write Dockerfile/shell variable inventory CSV.
                           Default: ./docker-context-checker-variables.csv.
      --software-output FILE
                           Write installed/setup software inventory CSV.
                           Default: ./docker-context-checker-software.csv.
      --config-output FILE Write Java/JBoss setting audit CSV.
                           Default: ./docker-context-checker-config.csv.
      --ecs-env-output FILE
                           Write ECS task definition environment inventory CSV.
                           Default: ./docker-context-checker-ecs-env.csv.
      --container-check-output FILE
                           Write Docker runtime/EAP probe result CSV.
                           Default: ./docker-context-checker-container-checks.csv.
      --runtime-probe      Build the Docker image and run ksh/java executable probes.
                           Disabled by default because it starts Docker.
      --runtime-probe-image TAG
                           Image tag to use for --runtime-probe.
                           Default: docker-context-checker-probe:<timestamp>-<pid>.
      --runtime-probe-build-option ARG
                           Extra docker build option for --runtime-probe.
                           Repeat for secrets, build args, network options, etc.
      --runtime-probe-keep-image
                           Keep the temporary probe image after checks.
      --eap-startup-probe  Build and start the container, then inspect JBoss EAP
                           startup logs for server/deployment success.
      --eap-startup-target MODE
                           EAP probe target: build, from, or image. Default: build.
                           build: build this Dockerfile, from: run final FROM image,
                           image: run --eap-startup-run-image.
      --eap-startup-from-base
                           Shortcut for --eap-startup-target from.
      --eap-startup-timeout SEC
                           Seconds to wait for JBoss EAP startup logs. Default: 180.
      --eap-startup-image TAG
                           Image tag to build for --eap-startup-probe target=build.
      --eap-startup-run-image IMAGE
                           Existing image to run for --eap-startup-target image.
      --eap-startup-container NAME
                           Container name to use for --eap-startup-probe.
      --eap-startup-command CMD
                           Command string to run in the probe container via
                           /bin/sh -lc CMD. Useful for base images without CMD.
      --eap-startup-build-option ARG
                           Extra docker build option for --eap-startup-probe.
                           Repeat for secrets, build args, network options, etc.
      --eap-startup-run-option ARG
                           Extra docker run option for --eap-startup-probe.
                           Repeat for env, port, network, volume options, etc.
      --eap-startup-keep-image
                           Keep the temporary EAP probe image after checks.
      --eap-startup-keep-container
                           Keep the EAP probe container after checks.
      --include-unused-all Report every unreferenced file in the build context.
      --fail-on LEVEL      error, warn, or never. Default: error.
      --no-progress        Do not print phase-by-phase progress messages.
      --no-output          Do not write the CSV report file.
      --no-mermaid         Do not write the Mermaid relationship diagram.
      --no-ascii-art       Do not write the ASCII relationship diagram.
      --no-variables-output
                           Do not write the variable inventory CSV.
      --no-software-output Do not write the software inventory CSV.
      --no-config-output   Do not write the Java/JBoss setting audit CSV.
      --no-ecs-env-output  Do not write the ECS environment inventory CSV.
      --no-container-check-output
                           Do not write the Docker runtime/EAP probe result CSV.
      --no-runtime-probe   Disable Docker runtime probes.
      --no-eap-startup-probe
                           Disable JBoss EAP startup probe.
      --no-color           Disable ANSI colors.
  -h, --help               Show this help.
      --version            Show version.

Checks include:
  - Dockerfile FROM / multi-stage / COPY --from validation.
  - COPY and ADD source existence, .dockerignore exclusion, and context symlink health.
  - Symlink creation phase: Dockerfile RUN is build phase; entrypoint/called scripts
    are runtime phase.
  - Entrypoint and called shell variable checks: unused, empty initialization,
    use-before-init, required external values, and values without defaults.
  - Dockerfile BuildKit build secret mount syntax and required=true checks.
  - ECS task definition environment/secrets candidates detected from Dockerfile,
    entrypoint shells, and WildFly/JBoss CLI expressions.
  - Optional Docker runtime probe for ksh and java executability.
  - Optional JBoss EAP 8.1 startup log probe and deployed WAR detection.
  - Docker permission failures in probes retry once with sudo -n docker; if sudo
    fails, the probe records a warning and the report generation continues.
  - WildFly jboss-cli --file / --commands detection, CLI file syntax heuristics,
    and JNDI setting validation.
  - UBI 9.6 final image consistency, especially runtime entrypoint behavior.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

abs_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "$p"
  else
    local d b
    d=$(dirname -- "$p")
    b=$(basename -- "$p")
    (cd "$d" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$b") || printf '%s\n' "$p"
  fi
}

rel_to_context() {
  local p abs
  p="$1"
  abs=$(abs_path "$p")
  if [[ "$abs" == "$CONTEXT_DIR" ]]; then
    printf '.'
  elif [[ "$abs" == "$CONTEXT_DIR/"* ]]; then
    printf '%s' "${abs#"$CONTEXT_DIR/"}"
  else
    printf '%s' "$abs"
  fi
}

display_path() {
  local p="$1"
  if [[ -z "$p" ]]; then
    printf '-'
    return
  fi
  if [[ "$p" == "$CONTEXT_DIR/"* || "$p" == "$CONTEXT_DIR" ]]; then
    rel_to_context "$p"
  else
    printf '%s' "$p"
  fi
}

progress_log() {
  local step="$1" msg="$2"
  (( PROGRESS )) || return 0
  printf '[%s] %-12s %s (ERROR=%s WARN=%s INFO=%s)\n' \
    "$(date '+%H:%M:%S')" "$step" "$msg" \
    "${F_COUNT[ERROR]:-0}" "${F_COUNT[WARN]:-0}" "${F_COUNT[INFO]:-0}" >&2
}

add_finding() {
  local sev="$1" phase="$2" file="$3" line="$4" code="$5" msg="$6"
  [[ -z "$line" || "$line" == "0" ]] && line="-"
  F_SEV+=("$sev")
  F_PHASE+=("$phase")
  F_FILE+=("$file")
  F_LINE+=("$line")
  F_CODE+=("$code")
  F_MSG+=("$msg")
  F_COUNT[$sev]=$(( ${F_COUNT[$sev]:-0} + 1 ))
}

add_relation() {
  local from="$1" to="$2" label="$3" phase="$4" file="$5" line="$6"
  local key
  [[ -z "$from" || -z "$to" ]] && return 0
  [[ -z "$line" || "$line" == "0" ]] && line="-"
  key="$from|$to|$label|$phase|$file|$line"
  [[ -n "${REL_SEEN[$key]:-}" ]] && return 0
  REL_SEEN["$key"]=1
  REL_FROM+=("$from")
  REL_TO+=("$to")
  REL_LABEL+=("$label")
  REL_PHASE+=("$phase")
  REL_FILE+=("$file")
  REL_LINE+=("$line")
}

add_var_record() {
  local name="$1" category="$2" action="$3" file="$4" line="$5" value="$6" phase="$7" note="$8"
  [[ -z "$name" ]] && return 0
  [[ -z "$line" || "$line" == "0" ]] && line="-"
  VAR_NAME+=("$name")
  VAR_CATEGORY+=("$category")
  VAR_ACTION+=("$action")
  VAR_FILE+=("$file")
  VAR_LINE+=("$line")
  VAR_VALUE+=("$value")
  VAR_PHASE+=("$phase")
  VAR_NOTE+=("$note")
}

add_software_record() {
  local name="$1" type="$2" version="$3" source="$4" phase="$5" file="$6" line="$7" evidence="$8" note="$9"
  local key
  [[ -z "$name" ]] && return 0
  [[ -z "$line" || "$line" == "0" ]] && line="-"
  key="$name|$type|$version|$source|$phase|$file|$line|$evidence"
  [[ -n "${SW_SEEN[$key]:-}" ]] && return 0
  SW_SEEN["$key"]=1
  SW_NAME+=("$name")
  SW_TYPE+=("$type")
  SW_VERSION+=("$version")
  SW_SOURCE+=("$source")
  SW_PHASE+=("$phase")
  SW_FILE+=("$file")
  SW_LINE+=("$line")
  SW_EVIDENCE+=("$evidence")
  SW_NOTE+=("$note")
}

add_config_record() {
  local domain="$1" component="$2" setting="$3" description="$4" value="$5" recommended="$6" distance="$7" severity="$8" phase="$9" file="${10}" line="${11}" evidence="${12}"
  local key
  [[ -z "$setting" ]] && return 0
  [[ -z "$line" || "$line" == "0" ]] && line="-"
  [[ -z "$value" ]] && value="(empty)"
  [[ -z "$recommended" ]] && recommended="(context-dependent)"
  [[ -z "$distance" ]] && distance="N/A"
  [[ -z "$severity" ]] && severity="INFO"
  key="$domain|$setting|$value|$file|$line"
  [[ -n "${CFG_SEEN[$key]:-}" ]] && return 0
  CFG_SEEN["$key"]=1
  CFG_DOMAIN+=("$domain")
  CFG_COMPONENT+=("$component")
  CFG_SETTING+=("$setting")
  CFG_DESCRIPTION+=("$description")
  CFG_VALUE+=("$value")
  CFG_RECOMMENDED+=("$recommended")
  CFG_DISTANCE+=("$distance")
  CFG_SEVERITY+=("$severity")
  CFG_PHASE+=("$phase")
  CFG_FILE+=("$file")
  CFG_LINE+=("$line")
  CFG_EVIDENCE+=("$evidence")
}

is_secret_like_var() {
  local name
  name="$(lower "$1")"
  case "$name" in
    *password*|*passwd*|*pwd*|*secret*|*token*|*credential*|*apikey*|*api_key*|*access_key*|*secret_key*|*private_key*|*cert*|*keystore*|*truststore*)
      return 0
      ;;
  esac
  return 1
}

ecs_taskdef_field_for_var() {
  if is_secret_like_var "$1"; then
    printf 'containerDefinitions[].secrets'
  else
    printf 'containerDefinitions[].environment'
  fi
}

should_report_docker_env_for_ecs() {
  local name="$1" lname
  lname="$(lower "$name")"
  case "$name" in
    PATH|HOME|PWD|OLDPWD|SHELL|USER|LOGNAME|HOSTNAME|LANG|LC_ALL|TERM|TMPDIR)
      return 1
      ;;
    JAVA_HOME|JBOSS_HOME|WILDFLY_HOME)
      return 0
      ;;
  esac
  if is_java_option_variable "$name" || is_secret_like_var "$name"; then
    return 0
  fi
  case "$lname" in
    *db*|*database*|*jdbc*|*url*|*host*|*port*|*endpoint*|*profile*|*env*|*stage*|*region*|*queue*|*topic*|*bucket*|*java*|*jvm*|*jboss*|*wildfly*)
      return 0
      ;;
  esac
  return 0
}

add_ecs_env_record() {
  local name="$1" requirement="$2" source="$3" file="$4" line="$5" current_value="$6" default_value="$7" reason="$8" evidence="$9"
  local field key
  [[ -z "$name" ]] && return 0
  [[ -z "$line" || "$line" == "0" ]] && line="-"
  field="$(ecs_taskdef_field_for_var "$name")"
  if is_secret_like_var "$name"; then
    reason="$reason Use ECS secrets with Secrets Manager or SSM Parameter Store rather than plain environment when the value is sensitive."
  fi
  key="$name|$requirement|$source|$file|$line|$evidence"
  [[ -n "${ECS_ENV_SEEN[$key]:-}" ]] && return 0
  ECS_ENV_SEEN["$key"]=1
  ECS_ENV_NAME+=("$name")
  ECS_ENV_REQUIREMENT+=("$requirement")
  ECS_ENV_SOURCE+=("$source")
  ECS_ENV_FILE+=("$file")
  ECS_ENV_LINE+=("$line")
  ECS_ENV_CURRENT_VALUE+=("$current_value")
  ECS_ENV_DEFAULT_VALUE+=("$default_value")
  ECS_ENV_TASKDEF_FIELD+=("$field")
  ECS_ENV_REASON+=("$reason")
  ECS_ENV_EVIDENCE+=("$evidence")
}

compact_output() {
  local s="$1"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ | }"
  while [[ "$s" == *"  "* ]]; do
    s="${s//  / }"
  done
  if ((${#s} > 700)); then
    s="${s:0:700}..."
  fi
  printf '%s' "$s"
}

output_has_permission_error() {
  grep -Eiq 'permission denied|access denied|operation not permitted|Got permission denied|dial unix .*permission|var/run/docker\.sock.*permission|docker_engine.*permission|open .*permission'
}

docker_capture() {
  local output rc sudo_output sudo_rc
  DOCKER_CAPTURE_OUTPUT=""
  DOCKER_CAPTURE_RC=0
  DOCKER_CAPTURE_PERMISSION=0
  DOCKER_CAPTURE_SUDO_ATTEMPTED=0
  DOCKER_CAPTURE_SUDO_FAILED=0

  if (( DOCKER_USE_SUDO )); then
    output="$(sudo -n docker "$@" 2>&1)"
    rc=$?
    if (( rc != 0 )) && printf '%s\n' "$output" | output_has_permission_error; then
      DOCKER_CAPTURE_PERMISSION=1
      DOCKER_CAPTURE_SUDO_ATTEMPTED=1
      DOCKER_CAPTURE_SUDO_FAILED=1
    fi
    DOCKER_CAPTURE_OUTPUT="$output"
    DOCKER_CAPTURE_RC="$rc"
    return "$rc"
  fi

  output="$(docker "$@" 2>&1)"
  rc=$?
  if (( rc != 0 )) && printf '%s\n' "$output" | output_has_permission_error; then
    DOCKER_CAPTURE_PERMISSION=1
    DOCKER_CAPTURE_SUDO_ATTEMPTED=1
    if command -v sudo >/dev/null 2>&1; then
      progress_log "SUDO" "Docker command hit a permission error; retrying with sudo -n docker $*"
      sudo_output="$(sudo -n docker "$@" 2>&1)"
      sudo_rc=$?
      if (( sudo_rc == 0 )); then
        DOCKER_USE_SUDO=1
        DOCKER_CAPTURE_OUTPUT="$sudo_output"
        DOCKER_CAPTURE_RC=0
        progress_log "SUDO" "sudo docker retry succeeded; continuing with sudo for later Docker commands"
        return 0
      fi
      DOCKER_CAPTURE_SUDO_FAILED=1
      DOCKER_CAPTURE_OUTPUT="$output"$'\n'"sudo retry failed: $sudo_output"
      DOCKER_CAPTURE_RC="$sudo_rc"
      return "$sudo_rc"
    fi
    DOCKER_CAPTURE_SUDO_FAILED=1
    DOCKER_CAPTURE_OUTPUT="$output"$'\n'"sudo retry failed: sudo command was not found"
    DOCKER_CAPTURE_RC="$rc"
    return "$rc"
  fi

  DOCKER_CAPTURE_OUTPUT="$output"
  DOCKER_CAPTURE_RC="$rc"
  return "$rc"
}

docker_permission_sudo_failed() {
  (( DOCKER_CAPTURE_PERMISSION && DOCKER_CAPTURE_SUDO_FAILED ))
}

docker_permission_warning_text() {
  printf 'Docker command failed due to permissions. sudo retry was attempted but did not succeed; skipping this Docker-backed operation and continuing. Output: %s' "$(compact_output "$DOCKER_CAPTURE_OUTPUT")"
}

is_final_build_phase() {
  [[ "$1" == "build:stage-$FINAL_STAGE" || "$1" == "build:final-stage" ]]
}

is_ksh_package_name() {
  local name
  name="$(lower "$1")"
  case "$name" in
    ksh|ksh-*|*ksh-20*|mksh|pdksh)
      return 0
      ;;
  esac
  return 1
}

is_java_package_name() {
  local name
  name="$(lower "$1")"
  if [[ -n "$(infer_java_version_from_text "$name")" ]]; then
    return 0
  fi
  case "$name" in
    java|java-*|openjdk|openjdk-*|jdk|jdk-*|jre|jre-*|*java-runtime*|*java-devel*)
      return 0
      ;;
  esac
  return 1
}

runtime_probe_expected_ksh() {
  (( FINAL_INSTALLS_KSH || FINAL_NEEDS_KSH || FINAL_DOCKERFILE_SHELL_KSH ))
}

runtime_probe_expected_java() {
  (( FINAL_INSTALLS_JAVA || FINAL_NEEDS_JAVA ))
}

is_number() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

numeric_range_distance() {
  local value="$1" min="$2" max="$3" unit="$4"
  if ! is_number "$value"; then
    printf 'Cannot compare: non-numeric value'
  elif awk "BEGIN { exit !($value < $min) }"; then
    awk "BEGIN { printf \"below recommended range by %.2f%s\", ($min - $value), \"$unit\" }"
  elif awk "BEGIN { exit !($value > $max) }"; then
    awk "BEGIN { printf \"above recommended range by %.2f%s\", ($value - $max), \"$unit\" }"
  else
    printf 'within recommended range'
  fi
}

numeric_range_severity() {
  local value="$1" min="$2" max="$3"
  if ! is_number "$value"; then
    printf 'WARN'
  elif awk "BEGIN { exit !($value < $min || $value > $max) }"; then
    printf 'WARN'
  else
    printf 'OK'
  fi
}

bool_distance() {
  local value="$1" recommended="$2"
  local v r
  v="$(lower "$value")"
  r="$(lower "$recommended")"
  case "$v" in
    true|false) ;;
    *) printf 'Cannot compare: non-boolean value'; return 0 ;;
  esac
  if [[ "$v" == "$r" ]]; then
    printf 'matches recommended value'
  else
    printf 'differs from recommended value'
  fi
}

bool_severity() {
  local value="$1" recommended="$2"
  [[ "$(lower "$value")" == "$(lower "$recommended")" ]] && printf 'OK' || printf 'WARN'
}

strip_shell_token() {
  local token="$1"
  token="${token%$'\r'}"
  token="${token%,}"
  token="${token%;}"
  token="${token%\"}"
  token="${token#\"}"
  token="${token%\'}"
  token="${token#\'}"
  printf '%s' "$token"
}

image_tag_version() {
  local image="$1"
  if [[ "$image" == *":"* ]]; then
    printf '%s' "${image##*:}"
  else
    printf 'latest/unspecified'
  fi
}

infer_java_version_from_text() {
  local text="$1" ltext
  ltext="$(lower "$text")"
  if [[ "$ltext" =~ (java|openjdk|jdk|jre)[^0-9]*(1\.8|8|11|17|21|22|23|24|25) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
  elif [[ "$ltext" =~ (1\.8|8|11|17|21|22|23|24|25)[^[:alnum:]]*(openjdk|jdk|jre) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf ''
  fi
}

infer_db_driver_vendor() {
  local name="$1" lname
  lname="$(lower "$name")"
  case "$lname" in
    *ojdbc*|*oracle*) printf 'Oracle JDBC driver' ;;
    *postgresql*|*pgsql*) printf 'PostgreSQL JDBC driver' ;;
    *mysql-connector*|*mysql*j*) printf 'MySQL JDBC driver' ;;
    *mariadb*) printf 'MariaDB JDBC driver' ;;
    *mssql-jdbc*|*sqljdbc*|*sqlserver*) printf 'Microsoft SQL Server JDBC driver' ;;
    *db2jcc*|*db2*) printf 'IBM DB2 JDBC driver' ;;
    *h2-*.jar|*h2.jar) printf 'H2 JDBC driver' ;;
    *hsqldb*) printf 'HSQLDB JDBC driver' ;;
    *derby*) printf 'Apache Derby JDBC driver' ;;
    *sqlite-jdbc*|*sqlite*) printf 'SQLite JDBC driver' ;;
    *jtds*) printf 'jTDS JDBC driver' ;;
    *snowflake*) printf 'Snowflake JDBC driver' ;;
    *redshift*) printf 'Amazon Redshift JDBC driver' ;;
    *terajdbc*|*tdgssconfig*|*teradata*) printf 'Teradata JDBC driver' ;;
    *) printf '' ;;
  esac
}

infer_version_from_filename() {
  local name="$1" base version
  base="$(basename -- "$name")"
  version="$(sed -n 's/.*[-_]\([0-9][0-9A-Za-z.+_-]*\)\.jar$/\1/p' <<< "$base" | head -n 1)"
  [[ -z "$version" ]] && version="$(sed -n 's/.*[-_]\([0-9][0-9A-Za-z.+_-]*\)\.\(tar\.gz\|tgz\|zip\|rpm\)$/\1/p' <<< "$base" | head -n 1)"
  printf '%s' "$version"
}

is_java_option_variable() {
  case "$1" in
    JAVA_OPTS|JAVA_TOOL_OPTIONS|JDK_JAVA_OPTIONS|JVM_OPTS|JBOSS_JAVA_OPTS|JAVA_OPTS_APPEND|JAVA_OPTS_PREPEND|CATALINA_OPTS|MAVEN_OPTS|GRADLE_OPTS|JAVA_ARGS)
      return 0
      ;;
  esac
  return 1
}

java_param_description() {
  local setting="$1"
  case "$setting" in
    -Xms) printf 'Initial Java heap size allocated when the JVM starts.' ;;
    -Xmx) printf 'Maximum Java heap size. In containers this must fit inside the cgroup memory limit together with metaspace, thread stacks, direct memory, native memory, and the OS.' ;;
    -Xss) printf 'Per-thread Java stack size. Larger values reduce the maximum practical thread count.' ;;
    -XX:MaxRAMPercentage) printf 'Maximum percentage of container memory that the JVM may use for heap when explicit -Xmx is not set.' ;;
    -XX:InitialRAMPercentage) printf 'Initial heap percentage of container memory when explicit -Xms is not set.' ;;
    -XX:MinRAMPercentage) printf 'Minimum heap percentage used by JVM ergonomics for small memory limits.' ;;
    -XX:MaxMetaspaceSize) printf 'Upper limit for class metadata memory. Too low can cause Metaspace OOM in WildFly deployments.' ;;
    -XX:MetaspaceSize) printf 'Metaspace size threshold that triggers the first GC for class metadata.' ;;
    -XX:MaxDirectMemorySize) printf 'Maximum off-heap direct buffer memory. Relevant for Undertow, NIO, database drivers, and messaging.' ;;
    -XX:ReservedCodeCacheSize) printf 'JIT compiled code cache size.' ;;
    -XX:UseContainerSupport) printf 'Enables JVM awareness of container cgroup CPU and memory limits.' ;;
    -XX:UseG1GC) printf 'Enables the G1 garbage collector, commonly suitable for Java 11+ server workloads.' ;;
    -XX:UseStringDeduplication) printf 'Enables String deduplication with G1GC to reduce heap usage when many duplicate strings exist.' ;;
    -XX:HeapDumpOnOutOfMemoryError) printf 'Writes a heap dump when an OutOfMemoryError occurs.' ;;
    -XX:HeapDumpPath) printf 'Path used for heap dump files.' ;;
    -XX:ExitOnOutOfMemoryError) printf 'Terminates the JVM on OutOfMemoryError so the container orchestrator can restart it.' ;;
    -XX:ErrorFile) printf 'Path pattern for fatal JVM error logs.' ;;
    -Dfile.encoding) printf 'Default JVM file encoding used by APIs that do not specify an encoding.' ;;
    -Duser.timezone) printf 'Default JVM timezone for date/time APIs that use the default zone.' ;;
    -Djava.security.egd) printf 'Entropy source used by Java security APIs. Historically tuned to avoid blocking startup.' ;;
    -Djboss.bind.address) printf 'WildFly/JBoss bind address for public interfaces.' ;;
    -Djboss.bind.address.management) printf 'WildFly/JBoss bind address for the management interface.' ;;
    -Djboss.server.config.dir) printf 'WildFly/JBoss server configuration directory.' ;;
    -Djboss.server.log.dir) printf 'WildFly/JBoss server log directory.' ;;
    -D*) printf 'Java system property passed to the JVM or application.' ;;
    -server) printf 'Selects the server JVM mode where available.' ;;
    --add-opens*) printf 'Opens a Java module/package reflectively for frameworks or legacy libraries.' ;;
    *) printf 'Java/JVM parameter detected in Dockerfile or shell script.' ;;
  esac
}

java_param_recommendation() {
  local setting="$1"
  case "$setting" in
    -Xms) printf 'Prefer container-aware percentage sizing unless startup latency requires fixed heap. If fixed, ensure -Xms <= -Xmx.' ;;
    -Xmx) printf 'Prefer -XX:MaxRAMPercentage=50-75 for containers, or set -Xmx below the container memory limit with headroom for non-heap memory.' ;;
    -Xss) printf 'Use the smallest stack size validated by the application; commonly 256k-1m depending on workload.' ;;
    -XX:MaxRAMPercentage) printf '50-75' ;;
    -XX:InitialRAMPercentage) printf '10-25' ;;
    -XX:MinRAMPercentage) printf '10-50' ;;
    -XX:UseContainerSupport) printf 'true' ;;
    -XX:UseG1GC) printf 'true for Java 11+ server workloads unless another GC is intentionally selected.' ;;
    -XX:UseStringDeduplication) printf 'true only after measuring duplicate-string heap pressure with G1GC.' ;;
    -XX:HeapDumpOnOutOfMemoryError) printf 'true, with HeapDumpPath pointing to writable storage if dumps are required.' ;;
    -XX:ExitOnOutOfMemoryError) printf 'true for containerized services so failures are restarted cleanly.' ;;
    -XX:MaxMetaspaceSize) printf 'Do not set too low; size from observed deployment metadata usage.' ;;
    -XX:MetaspaceSize) printf 'Tune only from GC/metaspace observations; avoid unnecessary fixed values.' ;;
    -XX:MaxDirectMemorySize) printf 'Set only when direct-memory usage must be bounded; include Undertow/NIO/driver requirements.' ;;
    -XX:ReservedCodeCacheSize) printf 'Tune only if code cache warnings appear; otherwise keep JVM default.' ;;
    -Dfile.encoding) printf 'UTF-8' ;;
    -Duser.timezone) printf 'UTC or the explicit business timezone required by the application.' ;;
    -Djava.security.egd) printf 'Modern Java usually needs no override; if set, prefer file:/dev/urandom.' ;;
    -Djboss.bind.address) printf '0.0.0.0 in containers when the service must listen on the container network.' ;;
    -Djboss.bind.address.management) printf 'Restrict management binding; avoid exposing 0.0.0.0 unless protected.' ;;
    -server) printf 'server mode is normally appropriate for application servers.' ;;
    --add-opens*) printf 'Use only for required compatibility; remove once dependencies support the Java module system.' ;;
    -D*) printf 'Application-specific; verify against application and WildFly documentation.' ;;
    *) printf 'Verify the option is supported by the Java version in the image.' ;;
  esac
}

java_param_distance() {
  local setting="$1" value="$2"
  local v
  v="${value%%%}"
  case "$setting" in
    -XX:MaxRAMPercentage)
      numeric_range_distance "$v" 50 75 "%"
      ;;
    -XX:InitialRAMPercentage)
      numeric_range_distance "$v" 10 25 "%"
      ;;
    -XX:MinRAMPercentage)
      numeric_range_distance "$v" 10 50 "%"
      ;;
    -XX:UseContainerSupport|-XX:HeapDumpOnOutOfMemoryError|-XX:ExitOnOutOfMemoryError)
      bool_distance "$value" "true"
      ;;
    -Dfile.encoding)
      [[ "$(lower "$value")" == "utf-8" || "$(lower "$value")" == "utf8" ]] && printf 'matches recommended value' || printf 'differs from recommended UTF-8'
      ;;
    -Xmx|-Xms|-Xss|-XX:MaxMetaspaceSize|-XX:MetaspaceSize|-XX:MaxDirectMemorySize|-XX:ReservedCodeCacheSize)
      printf 'Cannot compute without container memory limit and workload baseline'
      ;;
    *)
      printf 'N/A or context-dependent'
      ;;
  esac
}

java_param_severity() {
  local setting="$1" value="$2"
  local v
  v="${value%%%}"
  case "$setting" in
    -XX:MaxRAMPercentage)
      numeric_range_severity "$v" 50 75
      ;;
    -XX:InitialRAMPercentage)
      numeric_range_severity "$v" 10 25
      ;;
    -XX:MinRAMPercentage)
      numeric_range_severity "$v" 10 50
      ;;
    -XX:UseContainerSupport|-XX:HeapDumpOnOutOfMemoryError|-XX:ExitOnOutOfMemoryError)
      bool_severity "$value" "true"
      ;;
    -Dfile.encoding)
      [[ "$(lower "$value")" == "utf-8" || "$(lower "$value")" == "utf8" ]] && printf 'OK' || printf 'WARN'
      ;;
    *) printf 'INFO' ;;
  esac
}

record_java_parameter() {
  local setting="$1" value="$2" source="$3" phase="$4" file="$5" line="$6" evidence="$7"
  add_config_record "Java/JVM" "$source" "$setting" "$(java_param_description "$setting")" "$value" "$(java_param_recommendation "$setting")" "$(java_param_distance "$setting" "$value")" "$(java_param_severity "$setting" "$value")" "$phase" "$file" "$line" "$evidence"
}

scan_java_parameters() {
  local text="$1" source="$2" phase="$3" file="$4" line="$5"
  local token clean setting value prop
  while IFS= read -r token; do
    clean="$(strip_shell_token "$token")"
    if [[ "$clean" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      clean="${clean#*=}"
    fi
    clean="$(strip_shell_token "$clean")"
    case "$clean" in
      -Xms*)
        record_java_parameter "-Xms" "${clean#-Xms}" "$source" "$phase" "$file" "$line" "$text"
        ;;
      -Xmx*)
        record_java_parameter "-Xmx" "${clean#-Xmx}" "$source" "$phase" "$file" "$line" "$text"
        ;;
      -Xss*)
        record_java_parameter "-Xss" "${clean#-Xss}" "$source" "$phase" "$file" "$line" "$text"
        ;;
      -XX:+*)
        setting="-XX:${clean#-XX:+}"
        record_java_parameter "$setting" "true" "$source" "$phase" "$file" "$line" "$text"
        ;;
      -XX:-*)
        setting="-XX:${clean#-XX:-}"
        record_java_parameter "$setting" "false" "$source" "$phase" "$file" "$line" "$text"
        ;;
      -XX:*=*)
        setting="${clean%%=*}"
        value="${clean#*=}"
        record_java_parameter "$setting" "$value" "$source" "$phase" "$file" "$line" "$text"
        ;;
      -D*=*)
        prop="${clean%%=*}"
        value="${clean#*=}"
        record_java_parameter "$prop" "$value" "$source" "$phase" "$file" "$line" "$text"
        ;;
      -D*)
        record_java_parameter "$clean" "(flag/no explicit value)" "$source" "$phase" "$file" "$line" "$text"
        ;;
      -server|--add-opens*|--add-exports*|--illegal-access=*)
        setting="${clean%%=*}"
        value=""
        [[ "$clean" == *=* ]] && value="${clean#*=}"
        [[ -z "$value" ]] && value="enabled"
        record_java_parameter "$setting" "$value" "$source" "$phase" "$file" "$line" "$text"
        ;;
    esac
  done < <(printf '%s\n' "$text" | tr '[:space:]' '\n')
}

record_context_software_artifact() {
  local rel="$1" file="$2" line="$3" phase="$4" inst="$5"
  local base vendor version java_version lname
  base="$(basename -- "$rel")"
  lname="$(lower "$base")"
  version="$(infer_version_from_filename "$base")"

  if [[ "$lname" == *.jar ]]; then
    vendor="$(infer_db_driver_vendor "$base")"
    if [[ -n "$vendor" ]]; then
      add_software_record "$vendor" "database-driver-artifact" "$version" "$inst build-context artifact" "$phase" "$file" "$line" "$rel" "JDBC driver JAR copied or added from the build context."
    elif [[ "$lname" == *wildfly* || "$lname" == *jboss* ]]; then
      add_software_record "$base" "java-application-server-artifact" "$version" "$inst build-context artifact" "$phase" "$file" "$line" "$rel" "WildFly/JBoss related JAR artifact."
    else
      add_software_record "$base" "java-jar-artifact" "$version" "$inst build-context artifact" "$phase" "$file" "$line" "$rel" "JAR artifact copied or added from the build context."
    fi
  fi

  if [[ "$lname" == *.war || "$lname" == *.ear ]]; then
    add_software_record "$base" "java-deployment-artifact" "$version" "$inst build-context artifact" "$phase" "$file" "$line" "$rel" "Application deployment artifact copied or added from the build context."
  fi

  if [[ "$lname" == *wildfly* || "$lname" == *jboss-eap* ]]; then
    add_software_record "$base" "application-server-artifact" "$version" "$inst build-context artifact" "$phase" "$file" "$line" "$rel" "WildFly/JBoss package or artifact copied from the build context."
  fi

  java_version="$(infer_java_version_from_text "$base")"
  if [[ -n "$java_version" ]]; then
    add_software_record "Java" "java-artifact" "$java_version" "$inst build-context artifact" "$phase" "$file" "$line" "$rel" "Java/JDK/JRE related artifact copied from the build context."
  fi
}

record_installed_package() {
  local pkg="$1" manager="$2" file="$3" line="$4" phase="$5" evidence="$6"
  local clean version java_version lname vendor
  clean="$(strip_shell_token "$pkg")"
  [[ -z "$clean" || "$clean" == "-"* ]] && return 0
  [[ "$clean" == "\\" ]] && return 0
  case "$clean" in
    install|update|upgrade|localinstall|reinstall|clean|all) return 0 ;;
    "&&"|"||"|"|") return 0 ;;
  esac
  lname="$(lower "$clean")"
  version=""
  if [[ "$clean" == *"-"* ]]; then
    version="$(sed -n 's/.*-\([0-9][0-9A-Za-z.+_:~-]*\)$/\1/p' <<< "$clean" | head -n 1)"
  fi
  add_software_record "$clean" "os-package" "$version" "$manager install" "$phase" "$file" "$line" "$evidence" "Package installed or requested by package manager."

  if is_ksh_package_name "$clean"; then
    add_software_record "ksh" "shell-runtime-package" "$version" "$manager install package" "$phase" "$file" "$line" "$clean" "KornShell/ksh package inferred from installed package name."
    if is_final_build_phase "$phase"; then
      FINAL_INSTALLS_KSH=1
      add_finding "INFO" "$phase" "$file" "$line" "KSH001" "Dockerfile final stage installs or requests ksh package '$clean'."
    elif [[ "$phase" == runtime:* ]]; then
      add_finding "WARN" "$phase" "$file" "$line" "KSH004" "ksh package '$clean' appears to be installed at container runtime; prefer installing it in the Dockerfile build phase."
    fi
  fi

  java_version="$(infer_java_version_from_text "$clean")"
  if [[ -n "$java_version" ]]; then
    add_software_record "Java" "java-runtime-package" "$java_version" "$manager install package" "$phase" "$file" "$line" "$clean" "Java version inferred from installed package name."
  fi
  if is_java_package_name "$clean" && is_final_build_phase "$phase"; then
    FINAL_INSTALLS_JAVA=1
  fi

  vendor="$(infer_db_driver_vendor "$clean")"
  if [[ -n "$vendor" ]]; then
    add_software_record "$vendor" "database-driver-package" "$version" "$manager install package" "$phase" "$file" "$line" "$clean" "Database/JDBC driver package inferred from package name."
  fi

  if [[ "$lname" == *wildfly* || "$lname" == *jboss* ]]; then
    add_software_record "$clean" "application-server-package" "$version" "$manager install package" "$phase" "$file" "$line" "$clean" "WildFly/JBoss related package inferred from package name."
  fi
}

scan_software_commands() {
  local text="$1" file="$2" line="$3" phase="$4"
  local -a words=()
  local i j word cmd manager sub token url base version java_version lname
  # shellcheck disable=SC2206
  words=($text)
  for ((i=0; i<${#words[@]}; i++)); do
    word="$(strip_shell_token "${words[$i]}")"
    cmd="$(basename -- "$word")"
    lname="$(lower "$word")"
    case "$cmd" in
      dnf|yum|microdnf|apt|apt-get)
        manager="$cmd"
        if [[ $((i + 1)) -lt ${#words[@]} ]]; then
          sub="$(strip_shell_token "${words[$((i + 1))]}")"
          if [[ "$sub" == "install" || "$sub" == "localinstall" ]]; then
            for ((j=i+2; j<${#words[@]}; j++)); do
              token="$(strip_shell_token "${words[$j]}")"
              case "$token" in
                ""|";") break ;;
                "&&"|"||"|"|") break ;;
                -*) continue ;;
              esac
              record_installed_package "$token" "$manager" "$file" "$line" "$phase" "$text"
            done
          fi
        fi
        ;;
      rpm)
        if [[ $((i + 1)) -lt ${#words[@]} ]]; then
          for ((j=i+1; j<${#words[@]}; j++)); do
            token="$(strip_shell_token "${words[$j]}")"
            case "$token" in
              ""|";") break ;;
              "&&"|"||"|"|") break ;;
              -*) continue ;;
            esac
            if [[ "$token" == *.rpm ]]; then
              base="$(basename -- "$token")"
              version="$(infer_version_from_filename "$base")"
              add_software_record "$base" "rpm-package-file" "$version" "rpm install" "$phase" "$file" "$line" "$text" "RPM file installed directly."
            fi
          done
        fi
        ;;
      curl|wget)
        for ((j=i+1; j<${#words[@]}; j++)); do
          url="$(strip_shell_token "${words[$j]}")"
          case "$url" in
            http://*|https://*)
              base="$(basename -- "$url")"
              version="$(infer_version_from_filename "$base")"
              add_software_record "$base" "downloaded-setup-artifact" "$version" "$cmd download" "$phase" "$file" "$line" "$url" "Remote artifact downloaded during build/runtime setup."
              java_version="$(infer_java_version_from_text "$base")"
              if [[ -n "$java_version" ]]; then
                add_software_record "Java" "java-downloaded-artifact" "$java_version" "$cmd download" "$phase" "$file" "$line" "$url" "Java version inferred from downloaded artifact name."
              fi
              ;;
          esac
        done
        ;;
      tar|unzip)
        for ((j=i+1; j<${#words[@]}; j++)); do
          token="$(strip_shell_token "${words[$j]}")"
          case "$token" in
            *.tar.gz|*.tgz|*.zip)
              base="$(basename -- "$token")"
              version="$(infer_version_from_filename "$base")"
              add_software_record "$base" "extracted-setup-artifact" "$version" "$cmd extraction" "$phase" "$file" "$line" "$text" "Archive extracted as part of setup."
              ;;
          esac
        done
        ;;
      jboss-cli.sh|jboss-cli)
        add_software_record "WildFly/JBoss CLI" "application-server-management-tool" "" "jboss-cli command" "$phase" "$file" "$line" "$text" "jboss-cli is used to configure WildFly/JBoss."
        ;;
      java)
        if is_final_build_phase "$phase" || [[ "$phase" == runtime:* ]]; then
          FINAL_NEEDS_JAVA=1
        fi
        if [[ "$text" == *"-version"* ]]; then
          add_software_record "Java" "java-runtime-check" "" "java -version" "$phase" "$file" "$line" "$text" "Java runtime version is checked at build/runtime."
        else
          add_software_record "Java" "java-command-reference" "" "java command" "$phase" "$file" "$line" "$text" "Java command is invoked by Dockerfile or shell script."
        fi
        ;;
      ksh)
        if is_final_build_phase "$phase" || [[ "$phase" == runtime:* ]]; then
          FINAL_NEEDS_KSH=1
        fi
        add_software_record "ksh" "shell-command-reference" "" "ksh command" "$phase" "$file" "$line" "$text" "ksh command is invoked by Dockerfile or shell script."
        ;;
    esac
    if [[ "$lname" == *wildfly* || "$lname" == *jboss-eap* ]]; then
      version="$(infer_version_from_filename "$word")"
      add_software_record "$(basename -- "$word")" "application-server-setup-reference" "$version" "command reference" "$phase" "$file" "$line" "$text" "WildFly/JBoss setup reference detected in command line."
    fi
  done
}

parse_args() {
  while (($#)); do
    case "$1" in
      -c|--context)
        [[ $# -ge 2 ]] || die "$1 requires a directory"
        CONTEXT_DIR="$2"
        shift 2
        ;;
      -f|--dockerfile)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        DOCKERFILE_PATH="$2"
        shift 2
        ;;
      -e|--entrypoint)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        ENTRYPOINT_OVERRIDE="$2"
        shift 2
        ;;
      -o|--output)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        REPORT_FILE="$2"
        REPORT_ENABLED=1
        shift 2
        ;;
      --mermaid)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        MERMAID_FILE="$2"
        MERMAID_ENABLED=1
        shift 2
        ;;
      --ascii-art|--ascii)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        ASCII_ART_FILE="$2"
        ASCII_ART_ENABLED=1
        shift 2
        ;;
      --variables-output)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        VAR_REPORT_FILE="$2"
        VAR_REPORT_ENABLED=1
        shift 2
        ;;
      --software-output)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        SOFTWARE_REPORT_FILE="$2"
        SOFTWARE_REPORT_ENABLED=1
        shift 2
        ;;
      --config-output)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        CONFIG_REPORT_FILE="$2"
        CONFIG_REPORT_ENABLED=1
        shift 2
        ;;
      --ecs-env-output)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        ECS_ENV_REPORT_FILE="$2"
        ECS_ENV_REPORT_ENABLED=1
        shift 2
        ;;
      --container-check-output)
        [[ $# -ge 2 ]] || die "$1 requires a file"
        CONTAINER_CHECK_REPORT_FILE="$2"
        CONTAINER_CHECK_REPORT_ENABLED=1
        shift 2
        ;;
      --runtime-probe)
        RUNTIME_PROBE_ENABLED=1
        shift
        ;;
      --runtime-probe-image)
        [[ $# -ge 2 ]] || die "$1 requires an image tag"
        RUNTIME_PROBE_IMAGE="$2"
        RUNTIME_PROBE_IMAGE_CUSTOM=1
        RUNTIME_PROBE_ENABLED=1
        shift 2
        ;;
      --runtime-probe-build-option)
        [[ $# -ge 2 ]] || die "$1 requires a docker build option"
        RUNTIME_PROBE_BUILD_OPTIONS+=("$2")
        RUNTIME_PROBE_ENABLED=1
        shift 2
        ;;
      --runtime-probe-keep-image)
        RUNTIME_PROBE_KEEP_IMAGE=1
        RUNTIME_PROBE_ENABLED=1
        shift
        ;;
      --eap-startup-probe)
        EAP_STARTUP_PROBE_ENABLED=1
        shift
        ;;
      --eap-startup-target)
        [[ $# -ge 2 ]] || die "$1 requires build, from, or image"
        EAP_STARTUP_TARGET="$(lower "$2")"
        case "$EAP_STARTUP_TARGET" in
          build|from|image) ;;
          *) die "$1 requires build, from, or image" ;;
        esac
        EAP_STARTUP_PROBE_ENABLED=1
        shift 2
        ;;
      --eap-startup-from-base)
        EAP_STARTUP_TARGET="from"
        EAP_STARTUP_PROBE_ENABLED=1
        shift
        ;;
      --eap-startup-timeout)
        [[ $# -ge 2 ]] || die "$1 requires seconds"
        [[ "$2" =~ ^[0-9]+$ ]] || die "$1 requires a positive integer"
        EAP_STARTUP_TIMEOUT="$2"
        EAP_STARTUP_PROBE_ENABLED=1
        shift 2
        ;;
      --eap-startup-image)
        [[ $# -ge 2 ]] || die "$1 requires an image tag"
        EAP_STARTUP_IMAGE="$2"
        EAP_STARTUP_IMAGE_CUSTOM=1
        EAP_STARTUP_PROBE_ENABLED=1
        shift 2
        ;;
      --eap-startup-run-image|--eap-startup-existing-image)
        [[ $# -ge 2 ]] || die "$1 requires an image name"
        EAP_STARTUP_RUN_IMAGE="$2"
        EAP_STARTUP_TARGET="image"
        EAP_STARTUP_PROBE_ENABLED=1
        shift 2
        ;;
      --eap-startup-container)
        [[ $# -ge 2 ]] || die "$1 requires a container name"
        EAP_STARTUP_CONTAINER="$2"
        EAP_STARTUP_CONTAINER_CUSTOM=1
        EAP_STARTUP_PROBE_ENABLED=1
        shift 2
        ;;
      --eap-startup-command)
        [[ $# -ge 2 ]] || die "$1 requires a command string"
        EAP_STARTUP_COMMAND="$2"
        EAP_STARTUP_PROBE_ENABLED=1
        shift 2
        ;;
      --eap-startup-build-option)
        [[ $# -ge 2 ]] || die "$1 requires a docker build option"
        EAP_STARTUP_BUILD_OPTIONS+=("$2")
        EAP_STARTUP_PROBE_ENABLED=1
        shift 2
        ;;
      --eap-startup-run-option)
        [[ $# -ge 2 ]] || die "$1 requires a docker run option"
        EAP_STARTUP_RUN_OPTIONS+=("$2")
        EAP_STARTUP_PROBE_ENABLED=1
        shift 2
        ;;
      --eap-startup-keep-image)
        EAP_STARTUP_KEEP_IMAGE=1
        EAP_STARTUP_PROBE_ENABLED=1
        shift
        ;;
      --eap-startup-keep-container)
        EAP_STARTUP_KEEP_CONTAINER=1
        EAP_STARTUP_PROBE_ENABLED=1
        shift
        ;;
      --include-unused-all)
        INCLUDE_UNUSED_ALL=1
        shift
        ;;
      --fail-on)
        [[ $# -ge 2 ]] || die "$1 requires error, warn, or never"
        FAIL_ON="$2"
        shift 2
        ;;
      --no-color)
        NO_COLOR=1
        shift
        ;;
      --no-progress)
        PROGRESS=0
        shift
        ;;
      --no-output)
        REPORT_ENABLED=0
        shift
        ;;
      --no-mermaid)
        MERMAID_ENABLED=0
        shift
        ;;
      --no-ascii-art|--no-ascii)
        ASCII_ART_ENABLED=0
        shift
        ;;
      --no-variables-output)
        VAR_REPORT_ENABLED=0
        shift
        ;;
      --no-software-output)
        SOFTWARE_REPORT_ENABLED=0
        shift
        ;;
      --no-config-output)
        CONFIG_REPORT_ENABLED=0
        shift
        ;;
      --no-ecs-env-output)
        ECS_ENV_REPORT_ENABLED=0
        shift
        ;;
      --no-container-check-output)
        CONTAINER_CHECK_REPORT_ENABLED=0
        shift
        ;;
      --no-runtime-probe)
        RUNTIME_PROBE_ENABLED=0
        shift
        ;;
      --no-eap-startup-probe)
        EAP_STARTUP_PROBE_ENABLED=0
        shift
        ;;
      --version)
        printf '%s\n' "$VERSION"
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  case "$FAIL_ON" in
    error|warn|never) ;;
    *) die "--fail-on must be error, warn, or never" ;;
  esac
}

load_dockerignore() {
  local file="$CONTEXT_DIR/.dockerignore"
  [[ -f "$file" ]] || return 0

  local line no=0 pattern
  while IFS= read -r line || [[ -n "$line" ]]; do
    no=$((no + 1))
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"
    pattern="$(trim "$line")"
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    DOCKERIGNORE_PATTERNS["$no"]="$pattern"
    DOCKERIGNORE_ORDER+=("$no")
  done < "$file"
}

matches_dockerignore_pattern() {
  local rel="$1" pattern="$2"
  local basename_rel="${rel##*/}"
  pattern="${pattern#./}"
  pattern="${pattern%/}"
  [[ -z "$pattern" ]] && return 1

  if [[ "$pattern" == *"/"* ]]; then
    [[ "$rel" == $pattern || "$rel" == $pattern/* ]]
  else
    [[ "$basename_rel" == $pattern || "$rel" == */$pattern || "$rel" == $pattern ]]
  fi
}

is_dockerignored() {
  local rel="$1" ignored=1 id pattern neg
  rel="${rel#./}"
  for id in "${DOCKERIGNORE_ORDER[@]}"; do
    pattern="${DOCKERIGNORE_PATTERNS[$id]}"
    neg=0
    if [[ "$pattern" == !* ]]; then
      neg=1
      pattern="${pattern#!}"
    fi
    if matches_dockerignore_pattern "$rel" "$pattern"; then
      if ((neg)); then
        ignored=1
      else
        ignored=0
      fi
    fi
  done
  (( ignored == 0 ))
}

process_dockerfile_instruction() {
  local raw="$1" start="$2" end="$3" logical instr body idx upper current_stage
  logical=$(printf '%s\n' "$raw" | sed -e ':a' -e 'N' -e '$!ba' -e 's/\\[[:space:]]*\n/ /g')
  logical="$(trim "$logical")"
  [[ -z "$logical" || "$logical" == \#* ]] && return 0

  instr="${logical%%[[:space:]]*}"
  upper=$(printf '%s' "$instr" | tr '[:lower:]' '[:upper:]')
  body="${logical#"$instr"}"
  body="$(trim "$body")"

  if [[ "$upper" == "FROM" ]]; then
    parse_from_instruction "$body" "$start"
  fi

  current_stage="$FINAL_STAGE"
  idx="${#DF_INSTR[@]}"
  DF_INSTR[$idx]="$upper"
  DF_BODY[$idx]="$body"
  DF_START[$idx]="$start"
  DF_END[$idx]="$end"
  DF_STAGE[$idx]="$current_stage"
}

parse_from_instruction() {
  local body="$1" line="$2"
  local -a words=()
  local image="" stage_name="" i word lower_word
  # shellcheck disable=SC2206
  words=($body)

  for ((i=0; i<${#words[@]}; i++)); do
    word="${words[$i]}"
    [[ "$word" == --* ]] && continue
    image="$word"
    break
  done

  if [[ -z "$image" ]]; then
    FINAL_STAGE=$((FINAL_STAGE + 1))
    STAGE_BASE[$FINAL_STAGE]=""
    STAGE_NAME[$FINAL_STAGE]=""
    STAGE_LINE[$FINAL_STAGE]="$line"
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF001" "FROM instruction has no base image."
    return 0
  fi

  for ((; i<${#words[@]}; i++)); do
    lower_word="$(lower "${words[$i]}")"
    if [[ "$lower_word" == "as" && $((i + 1)) -lt ${#words[@]} ]]; then
      stage_name="${words[$((i + 1))]}"
      break
    fi
  done

  FINAL_STAGE=$((FINAL_STAGE + 1))
  STAGE_BASE[$FINAL_STAGE]="$image"
  STAGE_NAME[$FINAL_STAGE]="$stage_name"
  STAGE_LINE[$FINAL_STAGE]="$line"
  STAGE_WORKDIR_FINAL[$FINAL_STAGE]="/"
  add_software_record "$image" "container-base-image" "$(image_tag_version "$image")" "Dockerfile FROM${stage_name:+ AS $stage_name}" "build:stage-$FINAL_STAGE" "$DOCKERFILE_PATH" "$line" "$body" "Container base image used for this stage."
  local java_version image_l
  image_l="$(lower "$image")"
  java_version="$(infer_java_version_from_text "$image")"
  if [[ -n "$java_version" ]]; then
    add_software_record "Java" "java-runtime-from-base-image" "$java_version" "Dockerfile FROM image tag/name" "build:stage-$FINAL_STAGE" "$DOCKERFILE_PATH" "$line" "$image" "Java version inferred from the base image name or tag."
  fi
  if [[ "$image_l" == *wildfly* || "$image_l" == *jboss* ]]; then
    add_software_record "$image" "application-server-base-image" "$(image_tag_version "$image")" "Dockerfile FROM image tag/name" "build:stage-$FINAL_STAGE" "$DOCKERFILE_PATH" "$line" "$image" "WildFly/JBoss related base image."
  fi

  if [[ -n "$stage_name" ]]; then
    local key
    key="$(lower "$stage_name")"
    if [[ -n "${STAGE_BY_NAME[$key]:-}" ]]; then
      add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF002" "Duplicate multi-stage name '$stage_name'."
    else
      STAGE_BY_NAME[$key]="$FINAL_STAGE"
    fi
  fi
}

parse_dockerfile() {
  local line no=0 combined="" start=0 trimmed_line
  while IFS= read -r line || [[ -n "$line" ]]; do
    no=$((no + 1))
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"
    if [[ -z "$combined" ]]; then
      start="$no"
      combined="$line"
    else
      combined+=$'\n'"$line"
    fi
    trimmed_line="${line%"${line##*[![:space:]]}"}"
    if [[ "$trimmed_line" == *\\ && ! "$trimmed_line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    process_dockerfile_instruction "$combined" "$start" "$no"
    combined=""
  done < "$DOCKERFILE_PATH"

  if [[ -n "$combined" ]]; then
    process_dockerfile_instruction "$combined" "$start" "$no"
  fi

  if (( FINAL_STAGE < 0 )); then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "1" "DF003" "Dockerfile has no FROM instruction."
  fi
}

json_array_tokens() {
  awk '
  {
    in_string=0; esc=0; token="";
    for (i=1; i<=length($0); i++) {
      c=substr($0,i,1);
      if (in_string) {
        if (esc) { token=token c; esc=0; }
        else if (c=="\\") { esc=1; }
        else if (c=="\"") { print token; token=""; in_string=0; }
        else { token=token c; }
      } else if (c=="\"") {
        in_string=1;
      }
    }
  }'
}

normalize_context_source() {
  local src="$1"
  src="${src#./}"
  while [[ "$src" == /* ]]; do
    src="${src#/}"
  done
  printf '%s' "$src"
}

normalize_container_path() {
  local path="$1"
  printf '%s\n' "$path" | awk '
  BEGIN { FS="/"; OFS="/"; }
  {
    abs = ($0 ~ /^\//);
    n = split($0, part, "/");
    out_n = 0;
    for (i=1; i<=n; i++) {
      if (part[i] == "" || part[i] == ".") continue;
      if (part[i] == "..") {
        if (out_n > 0) out_n--;
        continue;
      }
      out[++out_n] = part[i];
    }
    if (abs) printf "/";
    for (i=1; i<=out_n; i++) {
      printf "%s", out[i];
      if (i < out_n) printf "/";
    }
    if (out_n == 0 && !abs) printf ".";
    printf "\n";
  }'
}

container_abs_path() {
  local workdir="$1" path="$2"
  if [[ "$path" == /* ]]; then
    normalize_container_path "$path"
  else
    normalize_container_path "$workdir/$path"
  fi
}

is_url() {
  [[ "$1" =~ ^https?:// || "$1" =~ ^ftp:// ]]
}

is_relevant_context_file() {
  local rel="$1"
  case "$rel" in
    Dockerfile|.dockerignore|README.md|docker-context-checker.sh|.gitattributes) return 1 ;;
    .git/*) return 1 ;;
  esac
  if (( INCLUDE_UNUSED_ALL )); then
    return 0
  fi
  case "$(lower "$rel")" in
    *.sh|*.bash|*.ksh|*.cli|*.xml|*.properties|*.conf|*.cfg|*.json|*.yaml|*.yml|*.war|*.ear|*.jar|*.pem|*.crt|*.key|*.sql)
      return 0
      ;;
  esac
  return 1
}

record_context_symlink() {
  local full="$1" rel target abs_target
  [[ -L "$full" ]] || return 0
  rel="$(rel_to_context "$full")"
  [[ -n "${CONTEXT_SYMLINK_SEEN[$rel]:-}" ]] && return 0
  CONTEXT_SYMLINK_SEEN[$rel]=1
  target="$(readlink "$full" 2>/dev/null || true)"
  if [[ ! -e "$full" ]]; then
    add_finding "ERROR" "build-context" "$full" "-" "CTX004" "Build context symlink '$rel' is broken; target is '$target'."
    return 0
  fi
  if [[ "$target" == /* ]]; then
    abs_target="$(abs_path "$target")"
  else
    abs_target="$(abs_path "$(dirname "$full")/$target")"
  fi
  if [[ "$abs_target" != "$CONTEXT_DIR/"* && "$abs_target" != "$CONTEXT_DIR" ]]; then
    add_finding "WARN" "build-context" "$full" "-" "CTX005" "Build context symlink '$rel' points outside the build context: $target"
  else
    add_finding "INFO" "build-context" "$full" "-" "CTX006" "Build context symlink '$rel' is provided by the host context before docker build; target: $target"
  fi
}

mark_context_path_referenced() {
  local full="$1" rel child
  record_context_symlink "$full"
  if [[ -d "$full" && ! -L "$full" ]]; then
    while IFS= read -r -d '' child; do
      rel="$(rel_to_context "$child")"
      REFERENCED_CONTEXT["$rel"]=1
      record_context_symlink "$child"
    done < <(find "$full" -path '*/.git' -prune -o -type f -print0 -o -type l -print0)
  else
    rel="$(rel_to_context "$full")"
    REFERENCED_CONTEXT["$rel"]=1
  fi
}

map_container_to_context_for_path() {
  local full="$1" src_rel="$2" dest="$3" src_count="$4" workdir="$5"
  local src_abs dest_abs dest_is_dir rel basename child child_rel inside cpath dest_base
  src_abs="$(abs_path "$full")"
  dest_abs="$(container_abs_path "$workdir" "$dest")"
  dest_is_dir=0
  [[ "$dest" == */ || "$src_count" -gt 1 ]] && dest_is_dir=1

  if [[ -d "$src_abs" && ! -L "$src_abs" ]]; then
    dest_base="$dest_abs"
    while IFS= read -r -d '' child; do
      child_rel="$(rel_to_context "$child")"
      inside="${child_rel#"$src_rel"/}"
      [[ "$inside" == "$child_rel" ]] && inside="${child_rel##*/}"
      cpath="$(normalize_container_path "$dest_base/$inside")"
      CONTAINER_TO_CONTEXT["$cpath"]="$child_rel"
      cpath="$(normalize_container_path "$dest_base/$(basename -- "$src_rel")/$inside")"
      CONTAINER_TO_CONTEXT["$cpath"]="$child_rel"
    done < <(find "$src_abs" -type f -print0 -o -type l -print0)
  else
    rel="$(rel_to_context "$src_abs")"
    basename="$(basename -- "$src_rel")"
    if (( dest_is_dir )); then
      cpath="$(normalize_container_path "$dest_abs/$basename")"
    else
      cpath="$dest_abs"
    fi
    CONTAINER_TO_CONTEXT["$cpath"]="$rel"
  fi
}

resolve_context_matches() {
  local src="$1" line="$2" inst="$3"
  local norm pattern full rel
  norm="$(normalize_context_source "$src")"
  if [[ "$norm" == *'$'* ]]; then
    add_finding "WARN" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX001" "$inst source '$src' contains a variable; static context existence cannot be fully resolved."
    return 0
  fi
  if [[ "$norm" == .. || "$norm" == ../* || "$norm" == */../* ]]; then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX002" "$inst source '$src' attempts to escape the build context."
    return 0
  fi
  if is_dockerignored "$norm"; then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX003" "$inst source '$src' is excluded by .dockerignore."
  fi

  if [[ "$norm" == *[\*\?\[]* ]]; then
    shopt -s nullglob globstar
    local -a matches=()
    mapfile -t matches < <(compgen -G "$CONTEXT_DIR/$norm" || true)
    shopt -u nullglob globstar
    if (( ${#matches[@]} == 0 )); then
      add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX007" "$inst source glob '$src' matches no build context files."
      return 0
    fi
    printf '%s\n' "${matches[@]}"
    return 0
  fi

  full="$CONTEXT_DIR/$norm"
  if [[ -e "$full" || -L "$full" ]]; then
    printf '%s\n' "$full"
  else
    rel="$norm"
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX008" "$inst source '$rel' does not exist in the build context."
  fi
}

validate_copy_from_reference() {
  local ref="$1" line="$2"
  local ref_l="$ref"
  ref_l="$(lower "$ref_l")"
  if [[ "$ref" =~ ^[0-9]+$ ]]; then
    if (( ref < 0 || ref > FINAL_STAGE )); then
      add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF004" "COPY --from=$ref references a stage index that does not exist."
    fi
    return 0
  fi
  if [[ -n "${STAGE_BY_NAME[$ref_l]:-}" ]]; then
    return 0
  fi
  if [[ "$ref" == *"/"* || "$ref" == *":"* || "$ref" == *"."* ]]; then
    add_finding "INFO" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF005" "COPY --from=$ref is treated as an external image, not a build-context resource."
  else
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF006" "COPY --from=$ref does not match any multi-stage alias or numeric stage."
  fi
}

add_copy_relations() {
  local full="$1" src_rel="$2" inst="$3" dest="$4" line="$5"
  local child child_rel
  if [[ -d "$full" && ! -L "$full" ]]; then
    while IFS= read -r -d '' child; do
      child_rel="$(rel_to_context "$child")"
      add_relation "Dockerfile" "$child_rel" "$inst line $line -> $dest" "build-context" "$DOCKERFILE_PATH" "$line"
      record_context_software_artifact "$child_rel" "$DOCKERFILE_PATH" "$line" "build-context" "$inst"
    done < <(find "$full" -path '*/.git' -prune -o -type f -print0 -o -type l -print0)
  else
    add_relation "Dockerfile" "$src_rel" "$inst line $line -> $dest" "build-context" "$DOCKERFILE_PATH" "$line"
    record_context_software_artifact "$src_rel" "$DOCKERFILE_PATH" "$line" "build-context" "$inst"
  fi
}

parse_copy_add_instruction() {
  local inst="$1" body="$2" line="$3" stage="$4" workdir="$5"
  local prefix json_part word from="" skip_next=0 link=0
  local -a tokens=() operands=() sources=() matches=()
  local dest src full src_rel i

  # shellcheck disable=SC2206
  local -a raw_words=($body)
  for ((i=0; i<${#raw_words[@]}; i++)); do
    word="${raw_words[$i]}"
    if ((skip_next)); then
      skip_next=0
      continue
    fi
    case "$word" in
      --from=*) from="${word#--from=}" ;;
      --from) [[ $((i + 1)) -lt ${#raw_words[@]} ]] && from="${raw_words[$((i + 1))]}" && skip_next=1 ;;
      --link) link=1 ;;
    esac
  done
  [[ -n "$from" ]] && validate_copy_from_reference "$from" "$line"
  (( link )) && add_finding "INFO" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF007" "$inst uses --link; verify the target builder/runtime supports BuildKit link layer semantics."

  if [[ "$(trim "$body")" == *"["* ]]; then
    prefix="${body%%[*}"
    json_part="[${body#*[}"
    mapfile -t tokens < <(printf '%s\n' "$json_part" | json_array_tokens)
  else
    for word in "${raw_words[@]}"; do
      if ((skip_next)); then
        skip_next=0
        continue
      fi
      case "$word" in
        --from=*) continue ;;
        --from) skip_next=1; continue ;;
        --chown=*|--chmod=*|--link|--parents|--exclude=*) continue ;;
        --*) continue ;;
        *) tokens+=("${word%$'\r'}") ;;
      esac
    done
  fi

  if (( ${#tokens[@]} < 2 )); then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "DF008" "$inst has fewer than one source and one destination."
    return 0
  fi

  dest="${tokens[$((${#tokens[@]} - 1))]}"
  sources=("${tokens[@]:0:$((${#tokens[@]} - 1))}")

  if [[ -n "$from" ]]; then
    return 0
  fi

  for src in "${sources[@]}"; do
    if [[ "$inst" == "ADD" ]] && is_url "$src"; then
      add_finding "INFO" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "CTX009" "ADD downloads remote resource '$src'; static build-context checks do not apply."
      continue
    fi
    mapfile -t matches < <(resolve_context_matches "$src" "$line" "$inst")
    for full in "${matches[@]}"; do
      [[ -z "$full" ]] && continue
      src_rel="$(rel_to_context "$full")"
      mark_context_path_referenced "$full"
      add_copy_relations "$full" "$src_rel" "$inst" "$dest" "$line"
      map_container_to_context_for_path "$full" "$src_rel" "$dest" "${#sources[@]}" "$workdir"
    done
  done
}

extract_var_refs() {
  awk '
  {
    s=$0
    for (i=1; i<=length(s); i++) {
      c=substr(s,i,1)
      if (c != "$") continue
      if (i > 1 && substr(s,i-1,1) == "\\") continue
      n=substr(s,i+1,1)
      if (n == "{") {
        j=i+2; expr=""
        while (j<=length(s) && substr(s,j,1)!="}") {
          expr=expr substr(s,j,1); j++
        }
        if (j>length(s)) continue
        if (substr(expr,1,1) == "!") expr=substr(expr,2)
        if (match(expr, /^[A-Za-z_][A-Za-z0-9_]*/)) {
          var=substr(expr,RSTART,RLENGTH)
          rest=substr(expr,RLENGTH+1)
          kind="plain"
          detail=""
          if (rest ~ /^:-/) { kind="default"; detail=substr(rest,3) }
          else if (rest ~ /^-/) { kind="default"; detail=substr(rest,2) }
          else if (rest ~ /^:=/) { kind="default"; detail=substr(rest,3) }
          else if (rest ~ /^=/) { kind="default"; detail=substr(rest,2) }
          else if (rest ~ /^:\?/) { kind="required"; detail=substr(rest,3) }
          else if (rest ~ /^\?/) { kind="required"; detail=substr(rest,2) }
          else if (rest ~ /^:\+/) { kind="alternate"; detail=substr(rest,3) }
          else if (rest ~ /^\+/) { kind="alternate"; detail=substr(rest,2) }
          gsub(/\|/, "/", detail)
          print var "|" kind "|" detail
        }
        i=j
      } else if (n ~ /[A-Za-z_]/) {
        j=i+1; var=""
        while (j<=length(s) && substr(s,j,1) ~ /[A-Za-z0-9_]/) {
          var=var substr(s,j,1); j++
        }
        print var "|plain|"
        i=j-1
      }
    }
  }'
}

extract_env_expr_refs() {
  awk '
  {
    s=$0
    for (i=1; i<=length(s); i++) {
      if (substr(s,i,2) == "${") {
        j=i+2; expr=""
        while (j<=length(s) && substr(s,j,1)!="}") {
          expr=expr substr(s,j,1); j++
        }
        if (j>length(s)) continue
        if (expr ~ /^env\.[A-Za-z_][A-Za-z0-9_]*(:[^}]*)?$/) {
          sub(/^env\./, "", expr)
          split(expr, parts, /[:-]/)
          print parts[1] "|wildfly-env-expression"
        } else if (expr ~ /^[A-Za-z_][A-Za-z0-9_]*(:[^}]*)?$/) {
          split(expr, parts, /[:-]/)
          print parts[1] "|expression"
        }
        i=j
      }
    }
  }'
}

is_standard_env_var() {
  case "$1" in
    PATH|HOME|PWD|OLDPWD|SHELL|USER|LOGNAME|HOSTNAME|LANG|LC_ALL|TERM|TMPDIR|TZ|UID|EUID|BASH|BASH_SOURCE|BASH_VERSION|LINENO|RANDOM|SECONDS|IFS|OPTIND|OPTARG|JAVA_HOME|JBOSS_HOME|WILDFLY_HOME|LAUNCH_JBOSS_IN_BACKGROUND)
      return 0
      ;;
  esac
  return 1
}

parse_env_instruction() {
  local body="$1" line="$2"
  local -a words=()
  local word key value
  scan_java_parameters "$body" "Dockerfile ENV" "build:dockerfile" "$DOCKERFILE_PATH" "$line"
  # shellcheck disable=SC2206
  words=($body)
  if (( ${#words[@]} == 0 )); then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR001" "ENV has no key/value."
    return 0
  fi
  if [[ "${words[0]}" != *=* ]]; then
    if (( ${#words[@]} >= 2 )); then
      key="${words[0]}"
      value="${words[*]:1}"
      DOCKER_ENV["$key"]="$value"
      DOCKER_ENV_LINE["$key"]="$line"
      add_var_record "$key" "Dockerfile ENV" "define" "$DOCKERFILE_PATH" "$line" "$value" "build:dockerfile" "Legacy ENV key value form; exported into the image environment."
      if should_report_docker_env_for_ecs "$key"; then
        if [[ -z "$value" || "$value" == '""' || "$value" == "''" ]]; then
          add_ecs_env_record "$key" "required_or_expected" "Dockerfile ENV empty/defaultless" "$DOCKERFILE_PATH" "$line" "$value" "" "Dockerfile defines this ENV as empty, so ECS task definition likely needs to provide the runtime value." "$body"
        else
          add_ecs_env_record "$key" "optional_override" "Dockerfile ENV default" "$DOCKERFILE_PATH" "$line" "$value" "$value" "Dockerfile provides a default ENV value, but ECS task definition can override it per environment." "$body"
        fi
      fi
      if is_java_option_variable "$key"; then
        scan_java_parameters "$value" "Dockerfile ENV $key" "build:dockerfile" "$DOCKERFILE_PATH" "$line"
      fi
      case "$key" in
        JAVA_VERSION|JDK_VERSION)
          add_software_record "Java" "java-version-env" "$value" "Dockerfile ENV $key" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "$body" "Java version configured through Dockerfile ENV."
          ;;
        JAVA_HOME)
          add_software_record "Java" "java-home-env" "" "Dockerfile ENV JAVA_HOME" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "$value" "Java home path configured through Dockerfile ENV."
          ;;
        JBOSS_HOME|WILDFLY_HOME)
          add_software_record "WildFly/JBoss" "application-server-home-env" "" "Dockerfile ENV $key" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "$value" "WildFly/JBoss home path configured through Dockerfile ENV."
          ;;
      esac
      add_finding "INFO" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR002" "ENV uses legacy 'key value' form; prefer key=value for predictable parsing."
    else
      add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR003" "ENV '$body' has no value."
    fi
    return 0
  fi
  for word in "${words[@]}"; do
    key="${word%%=*}"
    value="${word#*=}"
    DOCKER_ENV["$key"]="$value"
    DOCKER_ENV_LINE["$key"]="$line"
    add_var_record "$key" "Dockerfile ENV" "define" "$DOCKERFILE_PATH" "$line" "$value" "build:dockerfile" "ENV value exported into the image environment."
    if should_report_docker_env_for_ecs "$key"; then
      if [[ -z "$value" || "$value" == '""' || "$value" == "''" ]]; then
        add_ecs_env_record "$key" "required_or_expected" "Dockerfile ENV empty/defaultless" "$DOCKERFILE_PATH" "$line" "$value" "" "Dockerfile defines this ENV as empty, so ECS task definition likely needs to provide the runtime value." "$word"
      else
        add_ecs_env_record "$key" "optional_override" "Dockerfile ENV default" "$DOCKERFILE_PATH" "$line" "$value" "$value" "Dockerfile provides a default ENV value, but ECS task definition can override it per environment." "$word"
      fi
    fi
    if is_java_option_variable "$key"; then
      scan_java_parameters "$value" "Dockerfile ENV $key" "build:dockerfile" "$DOCKERFILE_PATH" "$line"
    fi
    case "$key" in
      JAVA_VERSION|JDK_VERSION)
        add_software_record "Java" "java-version-env" "$value" "Dockerfile ENV $key" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "$word" "Java version configured through Dockerfile ENV."
        ;;
      JAVA_HOME)
        add_software_record "Java" "java-home-env" "" "Dockerfile ENV JAVA_HOME" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "$value" "Java home path configured through Dockerfile ENV."
        ;;
      JBOSS_HOME|WILDFLY_HOME)
        add_software_record "WildFly/JBoss" "application-server-home-env" "" "Dockerfile ENV $key" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "$value" "WildFly/JBoss home path configured through Dockerfile ENV."
        ;;
    esac
    if [[ -z "$value" || "$value" == '""' || "$value" == "''" ]]; then
      add_finding "WARN" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR004" "ENV '$key' is initialized as empty."
    fi
  done
}

parse_arg_instruction() {
  local body="$1" line="$2" part key value
  part="$(trim "$body")"
  key="${part%%=*}"
  value=""
  [[ "$part" == *=* ]] && value="${part#*=}"
  if [[ -z "$key" ]]; then
    add_finding "ERROR" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR005" "ARG has no name."
    return 0
  fi
  DOCKER_ARG["$key"]="$value"
  DOCKER_ARG_LINE["$key"]="$line"
  if [[ "$part" == *=* ]]; then
    add_var_record "$key" "Dockerfile ARG" "define" "$DOCKERFILE_PATH" "$line" "$value" "build:dockerfile" "Build argument default value."
  else
    add_var_record "$key" "Dockerfile ARG" "define" "$DOCKERFILE_PATH" "$line" "" "build:dockerfile" "No default; must be supplied with --build-arg when required."
  fi
  if [[ "$part" != *=* ]]; then
    add_finding "WARN" "build:dockerfile" "$DOCKERFILE_PATH" "$line" "VAR006" "ARG '$key' has no default; it must be supplied by build-arg if required."
  fi
}

scan_dockerfile_var_use() {
  local text="$1" line="$2" phase="$3"
  local use var rest kind detail category note
  while IFS= read -r use; do
    [[ -z "$use" ]] && continue
    var="${use%%|*}"
    rest="${use#*|}"
    kind="${rest%%|*}"
    detail=""
    [[ "$rest" == *"|"* ]] && detail="${rest#*|}"
    DOCKER_VAR_USED["$var"]=1
    if [[ -v DOCKER_ARG[$var] ]]; then
      category="Dockerfile ARG reference"
    elif [[ -v DOCKER_ENV[$var] ]]; then
      category="Dockerfile ENV reference"
    else
      category="Dockerfile external/undefined variable"
    fi
    note="Variable reference in Dockerfile instruction."
    [[ "$kind" == "default" ]] && note="Variable reference has inline default/assignment fallback."
    [[ "$kind" == "required" ]] && note="Variable reference requires an external value."
    add_var_record "$var" "$category" "$kind" "$DOCKERFILE_PATH" "$line" "$detail" "$phase" "$note"
    if [[ "$kind" == "required" ]]; then
      add_finding "WARN" "$phase" "$DOCKERFILE_PATH" "$line" "VAR007" "Dockerfile variable '$var' is required via parameter expansion."
    elif [[ "$kind" == "plain" || "$kind" == "alternate" ]]; then
      if [[ ! -v DOCKER_ENV[$var] && ! -v DOCKER_ARG[$var] ]] && ! is_standard_env_var "$var"; then
        add_finding "WARN" "$phase" "$DOCKERFILE_PATH" "$line" "VAR008" "Dockerfile uses variable '$var' without an ARG/ENV definition or default."
      fi
    fi
  done < <(printf '%s\n' "$text" | extract_var_refs)
}

detect_symlink_command() {
  local text="$1"
  local re='(^|[[:space:];|&])ln[[:space:]][^#;|&]*-[A-Za-z]*s'
  [[ "$text" =~ $re ]]
}

check_build_secret_mounts() {
  local body="$1" line="$2" stage="$3"
  local -a words=()
  local -a mount_parts=()
  local word spec item key value id target env required mode seen_secret=0
  # shellcheck disable=SC2206
  words=($body)
  for word in "${words[@]}"; do
    [[ "$word" == --mount=* ]] || continue
    spec="${word#--mount=}"
    [[ "$spec" == *"type=secret"* ]] || continue
    seen_secret=1
    id=""
    target=""
    env=""
    required=""
    mode=""
    IFS=',' read -r -a mount_parts <<< "$spec"
    for item in "${mount_parts[@]}"; do
      key="${item%%=*}"
      value=""
      [[ "$item" == *=* ]] && value="${item#*=}"
      case "$key" in
        type)
          [[ "$value" == "secret" ]] || add_finding "ERROR" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC001" "RUN --mount uses type='$value' but this checker expected type=secret."
          ;;
        id)
          id="$value"
          [[ "$id" =~ ^[A-Za-z0-9_.-]+$ ]] || add_finding "WARN" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC002" "Build secret id '$id' contains unusual characters; keep ids simple for docker build --secret and CI mapping."
          ;;
        target|dst|destination)
          target="$value"
          [[ "$target" == /* ]] || add_finding "WARN" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC003" "Build secret target '$target' is not an absolute container path."
          ;;
        env)
          env="$value"
          [[ "$env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || add_finding "WARN" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC004" "Build secret env target '$env' is not a valid environment variable name."
          ;;
        required)
          required="$value"
          [[ "$required" == "true" || "$required" == "false" ]] || add_finding "ERROR" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC005" "Build secret required option must be true or false, got '$required'."
          ;;
        mode)
          mode="$value"
          [[ "$mode" =~ ^0?[0-7]{3,4}$ ]] || add_finding "WARN" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC006" "Build secret mode '$mode' is not an octal permission such as 0400."
          ;;
        uid|gid)
          [[ "$value" =~ ^[0-9]+$ ]] || add_finding "WARN" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC007" "Build secret $key value '$value' should be numeric."
          ;;
        source|src)
          add_finding "WARN" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC008" "Dockerfile secret mounts should not specify '$key'; provide source mapping with docker build --secret outside the Dockerfile."
          ;;
        *)
          add_finding "INFO" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC009" "Unknown build secret mount option '$key'; verify BuildKit supports it."
          ;;
      esac
    done
    if [[ -z "$id" ]]; then
      add_finding "WARN" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC010" "Build secret mount has no id= option; define an explicit id to map from docker build --secret or CI."
    fi
    if [[ -z "$target" && -z "$env" ]]; then
      add_finding "INFO" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC011" "Build secret '$id' uses BuildKit default target /run/secrets/<id>."
    fi
    if [[ "$required" != "true" ]]; then
      add_finding "WARN" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC012" "Build secret '${id:-unknown}' is not marked required=true; builds may silently proceed without the secret."
    fi
    add_finding "INFO" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC013" "BuildKit build secret mount detected: id='${id:-}' target='${target:-}' env='${env:-}' required='${required:-false}'."
  done
  if [[ "$body" == *"type=secret"* && "$seen_secret" -eq 0 ]]; then
    add_finding "WARN" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SEC014" "Line contains type=secret but no RUN --mount=type=secret option was parsed; verify Dockerfile BuildKit syntax."
  fi
}

find_context_by_basename() {
  local name="$1"
  find "$CONTEXT_DIR" -path '*/.git' -prune -o -type f -name "$name" -print | head -n 1
}

add_shell_file() {
  local rel="$1" reason="$2"
  [[ -z "$rel" ]] && return 0
  rel="${rel#./}"
  [[ -n "${SHELL_FILES[$rel]:-}" ]] && return 0
  SHELL_FILES["$rel"]=1
  SHELL_REASON["$rel"]="$reason"
}

add_cli_file() {
  local rel="$1" reason="$2"
  [[ -z "$rel" ]] && return 0
  rel="${rel#./}"
  [[ -n "${CLI_FILES[$rel]:-}" ]] && return 0
  CLI_FILES["$rel"]=1
  CLI_REASON["$rel"]="$reason"
}

resolve_script_reference() {
  local token="$1" current_rel="$2" line="$3" phase="$4" workdir="$5"
  local cleaned="$token" full rel cpath bybase
  cleaned="${cleaned%\"}"
  cleaned="${cleaned#\"}"
  cleaned="${cleaned%\'}"
  cleaned="${cleaned#\'}"
  cleaned="${cleaned%;}"
  cleaned="${cleaned%%#*}"
  cleaned="${cleaned%%\?*}"
  cleaned="${cleaned%%:*}"
  [[ -z "$cleaned" || "$cleaned" == *'$'* || "$cleaned" == *'*'* ]] && return 1

  if [[ "$cleaned" == /* ]]; then
    cpath="$(normalize_container_path "$cleaned")"
    if [[ -n "${CONTAINER_TO_CONTEXT[$cpath]:-}" ]]; then
      printf '%s\n' "${CONTAINER_TO_CONTEXT[$cpath]}"
      return 0
    fi
    bybase="$(find_context_by_basename "$(basename -- "$cleaned")")"
    if [[ -n "$bybase" ]]; then
      rel="$(rel_to_context "$bybase")"
      add_finding "INFO" "$phase" "$DOCKERFILE_PATH" "$line" "SH001" "Resolved '$cleaned' by basename to '$rel'; verify container path mapping."
      printf '%s\n' "$rel"
      return 0
    fi
    return 1
  fi

  if [[ -n "$current_rel" ]]; then
    full="$CONTEXT_DIR/$(dirname "$current_rel")/$cleaned"
    if [[ -f "$full" || -L "$full" ]]; then
      rel="$(rel_to_context "$full")"
      printf '%s\n' "$rel"
      return 0
    fi
  fi

  full="$CONTEXT_DIR/$cleaned"
  if [[ -f "$full" || -L "$full" ]]; then
    rel="$(rel_to_context "$full")"
    printf '%s\n' "$rel"
    return 0
  fi

  if [[ -n "$workdir" ]]; then
    cpath="$(container_abs_path "$workdir" "$cleaned")"
    if [[ -n "${CONTAINER_TO_CONTEXT[$cpath]:-}" ]]; then
      printf '%s\n' "${CONTAINER_TO_CONTEXT[$cpath]}"
      return 0
    fi
  fi

  bybase="$(find_context_by_basename "$(basename -- "$cleaned")")"
  if [[ -n "$bybase" ]]; then
    rel="$(rel_to_context "$bybase")"
    add_finding "INFO" "$phase" "$CONTEXT_DIR/$current_rel" "$line" "SH001" "Resolved '$cleaned' by basename to '$rel'; verify call path."
    printf '%s\n' "$rel"
    return 0
  fi
  return 1
}

discover_shell_refs_in_text() {
  local text="$1" current_rel="$2" line="$3" phase="$4" workdir="$5"
  local -a words=()
  local word next rel i
  # shellcheck disable=SC2206
  words=($text)
  for ((i=0; i<${#words[@]}; i++)); do
    word="${words[$i]}"
    word="${word%%[;&|]*}"
    case "$(basename -- "$word")" in
      sh|bash|ksh)
        if [[ $((i + 1)) -lt ${#words[@]} ]]; then
          next="${words[$((i + 1))]}"
          if [[ "$next" == -* && $((i + 2)) -lt ${#words[@]} ]]; then
            next="${words[$((i + 2))]}"
          fi
          if [[ "$next" == *.sh* || "$next" == *.ksh* || "$next" == ./* || "$next" == /* ]]; then
            if rel="$(resolve_script_reference "$next" "$current_rel" "$line" "$phase" "$workdir")"; then
              add_shell_file "$rel" "called from $phase line $line"
              add_relation "${current_rel:-Dockerfile}" "$rel" "calls line $line" "$phase" "$CONTEXT_DIR/$current_rel" "$line"
            else
              local key="$current_rel:$line:$next"
              if [[ -z "${MISSING_PATH_SEEN[$key]:-}" ]]; then
                MISSING_PATH_SEEN[$key]=1
                add_finding "WARN" "$phase" "$CONTEXT_DIR/$current_rel" "$line" "SH002" "Called shell script '$next' could not be resolved to a build-context file."
              fi
            fi
          fi
        fi
        ;;
      .|source)
        if [[ $((i + 1)) -lt ${#words[@]} ]]; then
          next="${words[$((i + 1))]}"
          if rel="$(resolve_script_reference "$next" "$current_rel" "$line" "$phase" "$workdir")"; then
            add_shell_file "$rel" "sourced from $phase line $line"
            add_relation "${current_rel:-Dockerfile}" "$rel" "sources line $line" "$phase" "$CONTEXT_DIR/$current_rel" "$line"
          else
            add_finding "WARN" "$phase" "$CONTEXT_DIR/$current_rel" "$line" "SH003" "Sourced shell file '$next' could not be resolved to a build-context file."
          fi
        fi
        ;;
      *.sh|*.sh\"|*.sh\'|*.ksh|*.ksh\"|*.ksh\')
        if (( i > 0 )); then
          local prev prev_base
          prev="${words[$((i - 1))]}"
          prev="${prev%%[;&|]*}"
          prev_base="$(basename -- "$prev")"
          case "$prev_base" in
            sh|bash|ksh|source|.) continue ;;
          esac
        fi
        if rel="$(resolve_script_reference "$word" "$current_rel" "$line" "$phase" "$workdir")"; then
          add_shell_file "$rel" "referenced from $phase line $line"
          add_relation "${current_rel:-Dockerfile}" "$rel" "references line $line" "$phase" "$CONTEXT_DIR/$current_rel" "$line"
        fi
        ;;
    esac
  done
}

extract_entrypoint_script_token() {
  local body="$1"
  local -a tokens=()
  if [[ "$(trim "$body")" == "["* ]]; then
    mapfile -t tokens < <(printf '%s\n' "$body" | json_array_tokens)
  else
    # shellcheck disable=SC2206
    tokens=($body)
  fi
  (( ${#tokens[@]} == 0 )) && return 1

  local first="${tokens[0]}"
  local base
  base="$(basename -- "$first")"
  case "$base" in
    sh|bash|ksh)
      if (( ${#tokens[@]} >= 2 )); then
        if [[ "${tokens[1]}" == "-c" ]]; then
          return 1
        fi
        printf '%s\n' "${tokens[1]}"
        return 0
      fi
      ;;
    *)
      printf '%s\n' "$first"
      return 0
      ;;
  esac
  return 1
}

detect_ubi_final_image() {
  local img
  FINAL_BASE="${STAGE_BASE[$FINAL_STAGE]:-}"
  img="$(lower "$FINAL_BASE")"
  [[ "$img" == *ubi9* || "$img" == *universal-base-image-9* ]] && FINAL_IS_UBI9=1
  [[ "$img" == *9.6* ]] && FINAL_IS_UBI96=1
  [[ "$img" == *ubi-minimal* || "$img" == *minimal* ]] && FINAL_IS_UBI_MINIMAL=1

  if (( FINAL_IS_UBI9 )) && (( ! FINAL_IS_UBI96 )); then
    add_finding "WARN" "runtime:final-stage" "$DOCKERFILE_PATH" "${STAGE_LINE[$FINAL_STAGE]:-1}" "UBI001" "Final image is UBI 9 family but is not pinned to 9.6: $FINAL_BASE"
  fi
  if [[ "$img" == *":latest"* || "$img" != *":"* ]]; then
    add_finding "WARN" "runtime:final-stage" "$DOCKERFILE_PATH" "${STAGE_LINE[$FINAL_STAGE]:-1}" "UBI002" "Final base image tag is not explicit enough for RHEL/UBI 9.6 reproducibility: $FINAL_BASE"
  fi
}

check_ubi_run_instruction() {
  local body="$1" line="$2" stage="$3"
  (( stage == FINAL_STAGE )) || return 0
  (( FINAL_IS_UBI9 )) || return 0
  local lbody re_bash re_yum_dnf re_microdnf re_service
  lbody="$(lower "$body")"
  re_bash='(^|[[:space:];&|])bash([[:space:];&|]|$)'
  re_yum_dnf='(^|[[:space:];&|])(yum|dnf)[[:space:]]+install'
  re_microdnf='(^|[[:space:];&|])microdnf[[:space:]]+install'
  re_service='(^|[[:space:];&|])(systemctl|service)[[:space:]]'

  if [[ "$lbody" =~ $re_bash || "$lbody" == *"install bash"* ]]; then
    FINAL_INSTALLS_BASH=1
  fi
  if (( FINAL_IS_UBI_MINIMAL )) && [[ "$lbody" =~ $re_yum_dnf ]]; then
    add_finding "WARN" "build:final-stage" "$DOCKERFILE_PATH" "$line" "UBI003" "UBI minimal images normally use microdnf; verify yum/dnf exists or install strategy is valid."
  fi
  if [[ "$lbody" =~ $re_microdnf ]] && [[ "$lbody" != *"clean all"* ]]; then
    add_finding "INFO" "build:final-stage" "$DOCKERFILE_PATH" "$line" "UBI004" "microdnf install is not followed by clean all in the same RUN; check image size and package cache cleanup."
  fi
  if [[ "$lbody" == *"subscription-manager"* ]]; then
    add_finding "WARN" "build:final-stage" "$DOCKERFILE_PATH" "$line" "UBI005" "subscription-manager appears in a UBI final stage; UBI images should not depend on host subscription state at runtime."
  fi
  if [[ "$lbody" =~ $re_service ]]; then
    add_finding "WARN" "build:final-stage" "$DOCKERFILE_PATH" "$line" "UBI006" "systemctl/service usage is suspicious inside a container image."
  fi
}

check_ksh_run_instruction() {
  local body="$1" line="$2" stage="$3"
  (( stage == FINAL_STAGE )) || return 0
  local lbody re_ksh
  lbody="$(lower "$body")"
  re_ksh='(^|[[:space:];&|(/])ksh([[:space:];&|),]|$)'
  if [[ "$lbody" =~ $re_ksh ]]; then
    FINAL_NEEDS_KSH=1
    if (( ! FINAL_INSTALLS_KSH )); then
      add_finding "WARN" "build:final-stage" "$DOCKERFILE_PATH" "$line" "KSH002" "Final stage uses ksh but ksh setup was not clearly detected earlier in the Dockerfile final stage. Enable --runtime-probe to confirm executability."
    fi
  fi
}

check_ksh_shell_instruction() {
  local body="$1" line="$2" stage="$3"
  (( stage == FINAL_STAGE )) || return 0
  local lbody
  lbody="$(lower "$body")"
  if [[ "$lbody" == *"ksh"* ]]; then
    FINAL_DOCKERFILE_SHELL_KSH=1
    FINAL_NEEDS_KSH=1
    if (( ! FINAL_INSTALLS_KSH )); then
      add_finding "WARN" "build:final-stage" "$DOCKERFILE_PATH" "$line" "KSH003" "Dockerfile SHELL uses ksh, but ksh setup was not clearly detected earlier in the Dockerfile final stage. Enable --runtime-probe to confirm executability."
    fi
  fi
}

analyze_dockerfile() {
  local -a stage_workdir=()
  local i inst body line stage workdir value key user
  for ((i=0; i<=FINAL_STAGE; i++)); do
    stage_workdir[$i]="/"
  done

  detect_ubi_final_image

  for ((i=0; i<${#DF_INSTR[@]}; i++)); do
    inst="${DF_INSTR[$i]}"
    body="${DF_BODY[$i]}"
    line="${DF_START[$i]}"
    stage="${DF_STAGE[$i]}"
    [[ "$stage" -lt 0 ]] && stage=0
    workdir="${stage_workdir[$stage]:-/}"

    case "$inst" in
      ARG)
        parse_arg_instruction "$body" "$line"
        ;;
      ENV)
        parse_env_instruction "$body" "$line"
        ;;
      WORKDIR)
        value="$(trim "$body")"
        stage_workdir[$stage]="$(container_abs_path "$workdir" "$value")"
        STAGE_WORKDIR_FINAL[$stage]="${stage_workdir[$stage]}"
        ;;
      COPY|ADD)
        parse_copy_add_instruction "$inst" "$body" "$line" "$stage" "$workdir"
        ;;
      RUN)
        check_build_secret_mounts "$body" "$line" "$stage"
        scan_software_commands "$body" "$DOCKERFILE_PATH" "$line" "build:stage-$stage"
        scan_java_parameters "$body" "Dockerfile RUN" "build:stage-$stage" "$DOCKERFILE_PATH" "$line"
        if detect_symlink_command "$body"; then
          add_finding "INFO" "build:stage-$stage" "$DOCKERFILE_PATH" "$line" "SYM001" "Symlink creation detected in Dockerfile RUN; this happens during image build, not container start."
        fi
        discover_shell_refs_in_text "$body" "" "$line" "build:stage-$stage" "$workdir"
        check_ubi_run_instruction "$body" "$line" "$stage"
        check_ksh_run_instruction "$body" "$line" "$stage"
        ;;
      SHELL)
        check_ksh_shell_instruction "$body" "$line" "$stage"
        ;;
      ENTRYPOINT)
        if (( stage == FINAL_STAGE )); then
          FINAL_ENTRYPOINT_BODY="$body"
          FINAL_ENTRYPOINT_LINE="$line"
        fi
        ;;
      CMD)
        if (( stage == FINAL_STAGE )); then
          FINAL_CMD_BODY="$body"
          FINAL_CMD_LINE="$line"
        fi
        ;;
      USER)
        if (( stage == FINAL_STAGE )); then
          user="$(trim "$body")"
          FINAL_USER="$user"
          FINAL_USER_LINE="$line"
        fi
        ;;
    esac

    scan_dockerfile_var_use "$body" "$line" "build:stage-$stage"
  done

  FINAL_WORKDIR="${stage_workdir[$FINAL_STAGE]:-/}"

  for key in "${!DOCKER_ARG[@]}"; do
    if [[ -z "${DOCKER_VAR_USED[$key]:-}" ]]; then
      add_finding "INFO" "build:dockerfile" "$DOCKERFILE_PATH" "${DOCKER_ARG_LINE[$key]}" "VAR009" "ARG '$key' is defined but not referenced later in the Dockerfile."
    fi
  done

  if (( FINAL_IS_UBI96 )); then
    if [[ -z "$FINAL_USER" ]]; then
      add_finding "WARN" "runtime:final-stage" "$DOCKERFILE_PATH" "${STAGE_LINE[$FINAL_STAGE]:-1}" "UBI007" "Final UBI 9.6 stage does not set USER; container will run as root unless the base image defines another user."
    elif [[ "$(lower "$FINAL_USER")" == "root" || "$FINAL_USER" == "0" ]]; then
      add_finding "WARN" "runtime:final-stage" "$DOCKERFILE_PATH" "$FINAL_USER_LINE" "UBI008" "Final UBI 9.6 stage explicitly runs as root."
    fi
  fi
}

resolve_entrypoint() {
  local token rel full
  if [[ -n "$ENTRYPOINT_OVERRIDE" ]]; then
    full="$ENTRYPOINT_OVERRIDE"
    [[ "$full" != /* && ! "$full" =~ ^[A-Za-z]: ]] && full="$CONTEXT_DIR/$full"
    full="$(abs_path "$full")"
    if [[ -f "$full" || -L "$full" ]]; then
      rel="$(rel_to_context "$full")"
      add_shell_file "$rel" "entrypoint override"
      add_relation "Dockerfile" "$rel" "entrypoint override" "runtime:entrypoint" "$full" "-"
    else
      add_finding "ERROR" "runtime:entrypoint" "$full" "-" "EP001" "Entrypoint override file does not exist."
    fi
    return 0
  fi

  if [[ -n "$FINAL_ENTRYPOINT_BODY" ]]; then
    if token="$(extract_entrypoint_script_token "$FINAL_ENTRYPOINT_BODY")"; then
      if rel="$(resolve_script_reference "$token" "" "$FINAL_ENTRYPOINT_LINE" "runtime:entrypoint" "$FINAL_WORKDIR")"; then
        add_shell_file "$rel" "Dockerfile ENTRYPOINT line $FINAL_ENTRYPOINT_LINE"
        add_relation "Dockerfile" "$rel" "ENTRYPOINT line $FINAL_ENTRYPOINT_LINE" "runtime:entrypoint" "$DOCKERFILE_PATH" "$FINAL_ENTRYPOINT_LINE"
      else
        add_finding "WARN" "runtime:entrypoint" "$DOCKERFILE_PATH" "$FINAL_ENTRYPOINT_LINE" "EP002" "ENTRYPOINT '$token' could not be resolved to a build-context script. It may come from the base image or a generated file."
      fi
    else
      discover_shell_refs_in_text "$FINAL_ENTRYPOINT_BODY" "" "$FINAL_ENTRYPOINT_LINE" "runtime:entrypoint" "$FINAL_WORKDIR"
    fi
  elif [[ -n "$FINAL_CMD_BODY" ]]; then
    if token="$(extract_entrypoint_script_token "$FINAL_CMD_BODY")"; then
      if rel="$(resolve_script_reference "$token" "" "$FINAL_CMD_LINE" "runtime:cmd" "$FINAL_WORKDIR")"; then
        add_shell_file "$rel" "Dockerfile CMD line $FINAL_CMD_LINE"
        add_relation "Dockerfile" "$rel" "CMD line $FINAL_CMD_LINE" "runtime:cmd" "$DOCKERFILE_PATH" "$FINAL_CMD_LINE"
      fi
    fi
  else
    full="$(find "$CONTEXT_DIR" -path '*/.git' -prune -o -type f \( -iname 'entrypoint.sh' -o -iname '*entrypoint*.sh' -o -iname 'entrypoint.ksh' -o -iname '*entrypoint*.ksh' \) -print | head -n 1)"
    if [[ -n "$full" ]]; then
      rel="$(rel_to_context "$full")"
      add_shell_file "$rel" "entrypoint filename heuristic"
      add_relation "Dockerfile" "$rel" "entrypoint filename heuristic" "runtime:entrypoint" "$full" "-"
      add_finding "INFO" "runtime:entrypoint" "$full" "-" "EP003" "No Dockerfile ENTRYPOINT found; scanning '$rel' by filename heuristic."
    else
      add_finding "INFO" "runtime:entrypoint" "$DOCKERFILE_PATH" "-" "EP004" "No ENTRYPOINT/CMD shell script could be resolved from the final stage."
    fi
  fi
}

literal_value_from_assignment() {
  local value="$1"
  value="$(trim "$value")"
  value="${value%%#*}"
  value="$(trim "$value")"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

substitute_known_vars() {
  local text="$1"
  shift
  local pair var value
  for pair in "$@"; do
    var="${pair%%=*}"
    value="${pair#*=}"
    text="${text//\$\{$var\}/$value}"
    text="${text//\$$var/$value}"
  done
  printf '%s' "$text"
}

extract_jboss_cli_file_arg() {
  local line="$1"
  awk '
  {
    for (i=1; i<=NF; i++) {
      if ($i ~ /^--file=/) {
        sub(/^--file=/, "", $i); print $i; exit
      }
      if ($i == "--file" && i < NF) {
        print $(i+1); exit
      }
    }
  }' <<< "$line"
}

resolve_cli_reference() {
  local token="$1" current_rel="$2" line="$3" phase="$4"
  local cleaned="$token" full rel cpath bybase
  cleaned="${cleaned%\"}"
  cleaned="${cleaned#\"}"
  cleaned="${cleaned%\'}"
  cleaned="${cleaned#\'}"
  cleaned="${cleaned%;}"
  [[ -z "$cleaned" || "$cleaned" == *'$'* ]] && return 1

  if [[ "$cleaned" == /* ]]; then
    cpath="$(normalize_container_path "$cleaned")"
    if [[ -n "${CONTAINER_TO_CONTEXT[$cpath]:-}" ]]; then
      printf '%s\n' "${CONTAINER_TO_CONTEXT[$cpath]}"
      return 0
    fi
    bybase="$(find_context_by_basename "$(basename -- "$cleaned")")"
    if [[ -n "$bybase" ]]; then
      rel="$(rel_to_context "$bybase")"
      add_finding "INFO" "$phase" "$CONTEXT_DIR/$current_rel" "$line" "CLI001" "Resolved CLI file '$cleaned' by basename to '$rel'; verify container path mapping."
      printf '%s\n' "$rel"
      return 0
    fi
    return 1
  fi

  full="$CONTEXT_DIR/$(dirname "$current_rel")/$cleaned"
  if [[ -f "$full" || -L "$full" ]]; then
    rel="$(rel_to_context "$full")"
    printf '%s\n' "$rel"
    return 0
  fi

  full="$CONTEXT_DIR/$cleaned"
  if [[ -f "$full" || -L "$full" ]]; then
    rel="$(rel_to_context "$full")"
    printf '%s\n' "$rel"
    return 0
  fi

  bybase="$(find_context_by_basename "$(basename -- "$cleaned")")"
  if [[ -n "$bybase" ]]; then
    rel="$(rel_to_context "$bybase")"
    add_finding "INFO" "$phase" "$CONTEXT_DIR/$current_rel" "$line" "CLI001" "Resolved CLI file '$cleaned' by basename to '$rel'; verify call path."
    printf '%s\n' "$rel"
    return 0
  fi
  return 1
}

scan_shell_file() {
  local rel="$1" reason="$2"
  local file="$CONTEXT_DIR/$rel"
  [[ -f "$file" || -L "$file" ]] || return 0
  progress_log "CHECK" "Scanning shell script: $rel ($reason)"

  local -A assigned_line=()
  local -A used_count=()
  local -A first_use=()
  local -A literal_assign=()
  local -A exported=()
  local line no=0 code assign var value use rest kind detail lcode cli_arg cli_rel category note java_assignment_var
  local -a literal_pairs=()
  local re_assign='(^|[[:space:];&|])(export|local|readonly)?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)='
  local re_export='(^|[[:space:];&|])export[[:space:]]+'
  local re_read='(^|[[:space:];&|])read([[:space:]][^;&|]*)?[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)'
  local re_for='(^|[[:space:];&|])for[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+in[[:space:]]'
  local re_pkg='(^|[[:space:];&|])(yum|dnf|microdnf)[[:space:]]+install'
  local re_service='(^|[[:space:];&|])(systemctl|service)[[:space:]]'
  local re_useradd='(^|[[:space:];&|])(useradd|groupadd)[[:space:]]'

  while IFS= read -r line || [[ -n "$line" ]]; do
    no=$((no + 1))
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"

    if [[ "$no" == 1 && "$line" =~ ^#!.*bash ]]; then
      if (( FINAL_IS_UBI96 && FINAL_IS_UBI_MINIMAL && ! FINAL_INSTALLS_BASH )); then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "UBI009" "Script shebang requires bash, but final UBI 9.6 minimal stage does not clearly install bash."
      fi
    fi
    if [[ "$no" == 1 && "$line" =~ ^#!.*ksh ]]; then
      FINAL_NEEDS_KSH=1
      if (( ! FINAL_INSTALLS_KSH )); then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "KSH003" "Script shebang requires ksh, but ksh setup was not clearly detected in the Dockerfile final stage. Enable --runtime-probe to confirm executability."
      fi
    fi

    code="${line%%#*}"
    [[ -z "$(trim "$code")" ]] && continue

    if detect_symlink_command "$code"; then
      add_finding "INFO" "runtime:$rel" "$file" "$no" "SYM002" "Symlink creation detected in shell script; this happens during container runtime/startup."
    fi

    discover_shell_refs_in_text "$code" "$rel" "$no" "runtime:$rel" "$FINAL_WORKDIR"
    scan_software_commands "$code" "$file" "$no" "runtime:$rel"
    java_assignment_var=""
    if [[ "$code" =~ $re_assign ]]; then
      java_assignment_var="${BASH_REMATCH[3]}"
    fi
    if [[ -z "$java_assignment_var" ]] || ! is_java_option_variable "$java_assignment_var"; then
      scan_java_parameters "$code" "shell command" "runtime:$rel" "$file" "$no"
    fi

    if [[ "$code" =~ $re_assign ]]; then
      var="${BASH_REMATCH[3]}"
      assigned_line["$var"]="${assigned_line[$var]:-$no}"
      [[ "$code" =~ $re_export ]] && exported["$var"]=1
      value="${code#*=}"
      value="$(literal_value_from_assignment "$value")"
      literal_assign["$var"]="$value"
      if is_java_option_variable "$var"; then
        scan_java_parameters "$value" "shell variable $var" "runtime:$rel" "$file" "$no"
      fi
      if [[ -n "${exported[$var]:-}" ]]; then
        add_var_record "$var" "Shell exported environment variable" "assign/export" "$file" "$no" "$value" "runtime:$rel" "Assigned in shell and exported to child processes."
      else
        add_var_record "$var" "Shell variable" "assign" "$file" "$no" "$value" "runtime:$rel" "Assigned in shell script."
      fi
      case "$var" in
        JAVA_VERSION|JDK_VERSION)
          add_software_record "Java" "java-version-shell-variable" "$value" "shell variable $var" "runtime:$rel" "$file" "$no" "$code" "Java version configured in shell script."
          ;;
        JAVA_HOME)
          add_software_record "Java" "java-home-shell-variable" "" "shell variable JAVA_HOME" "runtime:$rel" "$file" "$no" "$value" "Java home path configured in shell script."
          ;;
        JBOSS_HOME|WILDFLY_HOME)
          add_software_record "WildFly/JBoss" "application-server-home-shell-variable" "" "shell variable $var" "runtime:$rel" "$file" "$no" "$value" "WildFly/JBoss home path configured in shell script."
          ;;
      esac
      if [[ -z "$value" ]]; then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "VAR010" "Variable '$var' is initialized empty."
      fi
    fi

    if [[ "$code" =~ $re_read ]]; then
      var="${BASH_REMATCH[3]}"
      assigned_line["$var"]="${assigned_line[$var]:-$no}"
      add_var_record "$var" "Shell variable" "read" "$file" "$no" "(stdin/runtime input)" "runtime:$rel" "Value is read at container runtime."
    fi

    if [[ "$code" =~ $re_for ]]; then
      var="${BASH_REMATCH[2]}"
      assigned_line["$var"]="${assigned_line[$var]:-$no}"
      add_var_record "$var" "Shell variable" "for-loop" "$file" "$no" "(iterator)" "runtime:$rel" "Loop variable assigned by for statement."
    fi

    literal_pairs=()
    for var in "${!literal_assign[@]}"; do
      literal_pairs+=("$var=${literal_assign[$var]}")
    done

    if [[ "$code" == *jboss-cli* ]]; then
      cli_arg="$(extract_jboss_cli_file_arg "$code")"
      cli_arg="$(substitute_known_vars "$cli_arg" "${literal_pairs[@]}")"
      if [[ -n "$cli_arg" ]]; then
        if cli_rel="$(resolve_cli_reference "$cli_arg" "$rel" "$no" "runtime:$rel")"; then
          add_cli_file "$cli_rel" "jboss-cli --file from $rel:$no"
          add_relation "$rel" "$cli_rel" "jboss-cli --file line $no" "runtime:$rel" "$file" "$no"
        else
          add_finding "WARN" "runtime:$rel" "$file" "$no" "CLI002" "jboss-cli --file target '$cli_arg' could not be resolved to a build-context CLI file."
        fi
      fi
      if [[ "$code" == *"--commands="* ]]; then
        check_inline_cli_commands "$code" "$file" "$no" "runtime:$rel"
      fi
    fi

    lcode="$(lower "$code")"
    if (( FINAL_IS_UBI96 )); then
      if [[ "$lcode" =~ $re_pkg ]]; then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "UBI010" "Package installation is being attempted from entrypoint/runtime shell on UBI 9.6; move this to Dockerfile build phase when possible."
      fi
      if [[ "$lcode" =~ $re_service ]]; then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "UBI011" "systemctl/service usage in a UBI 9.6 container entrypoint is suspicious."
      fi
      if [[ "$lcode" == *"subscription-manager"* ]]; then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "UBI012" "subscription-manager usage at runtime is inconsistent with portable UBI 9.6 containers."
      fi
      if (( FINAL_IS_UBI_MINIMAL )) && [[ "$lcode" =~ $re_useradd ]]; then
        add_finding "WARN" "runtime:$rel" "$file" "$no" "UBI013" "useradd/groupadd may be unavailable in UBI minimal runtime unless shadow-utils is installed."
      fi
    fi

    while IFS= read -r use; do
      [[ -z "$use" ]] && continue
      var="${use%%|*}"
      rest="${use#*|}"
      kind="${rest%%|*}"
      detail=""
      [[ "$rest" == *"|"* ]] && detail="${rest#*|}"
      used_count["$var"]=$(( ${used_count[$var]:-0} + 1 ))
      first_use["$var"]="${first_use[$var]:-$no}"
      if [[ -n "${assigned_line[$var]:-}" ]]; then
        category="Shell variable reference"
      elif [[ -v DOCKER_ENV[$var] ]]; then
        category="Dockerfile ENV runtime reference"
      elif is_standard_env_var "$var"; then
        category="Standard environment variable reference"
      else
        category="External/runtime environment variable reference"
      fi
      note="Variable reference in shell script."
      [[ "$kind" == "default" ]] && note="Reference has inline default/assignment fallback."
      [[ "$kind" == "required" ]] && note="Reference requires external/runtime value."
      add_var_record "$var" "$category" "$kind" "$file" "$no" "$detail" "runtime:$rel" "$note"
      if [[ "$kind" == "required" ]]; then
        add_ecs_env_record "$var" "required" "shell required expansion" "$file" "$no" "" "$detail" "Shell parameter expansion requires this variable at container runtime. Set it from ECS task definition." "$code"
        add_finding "WARN" "runtime:$rel" "$file" "$no" "VAR011" "Variable '$var' is required from outside or earlier initialization via \${$var:?...}."
      elif [[ "$kind" == "default" ]]; then
        if [[ -z "${assigned_line[$var]:-}" ]] && ! is_standard_env_var "$var"; then
          add_ecs_env_record "$var" "optional_override" "shell default expansion" "$file" "$no" "" "$detail" "Shell provides an inline default, but ECS task definition can override this value per environment." "$code"
        fi
      elif [[ "$kind" == "plain" || "$kind" == "alternate" ]]; then
        if [[ -z "${assigned_line[$var]:-}" && ! -v DOCKER_ENV[$var] ]] && ! is_standard_env_var "$var"; then
          add_ecs_env_record "$var" "likely_required" "shell external reference" "$file" "$no" "" "" "Shell references this variable without local initialization or Dockerfile ENV. Set it from ECS task definition if the application expects it." "$code"
          add_finding "WARN" "runtime:$rel" "$file" "$no" "VAR012" "Variable '$var' is used without local initialization, Dockerfile ENV, or a default; it likely must be supplied from outside."
        elif [[ -v DOCKER_ENV[$var] ]] && ! is_standard_env_var "$var"; then
          add_ecs_env_record "$var" "optional_override" "Dockerfile ENV used at runtime" "$file" "$no" "${DOCKER_ENV[$var]}" "${DOCKER_ENV[$var]}" "Dockerfile provides this ENV and the shell uses it; ECS task definition can override it per deployment." "$code"
        elif [[ -n "${assigned_line[$var]:-}" && "${assigned_line[$var]}" -gt "$no" ]]; then
          add_finding "WARN" "runtime:$rel" "$file" "$no" "VAR013" "Variable '$var' is used before its first initialization on line ${assigned_line[$var]}."
        fi
      fi
    done < <(printf '%s\n' "$code" | extract_var_refs)
  done < "$file"

  for var in "${!assigned_line[@]}"; do
    if [[ ${used_count[$var]:-0} -eq 0 ]]; then
      if [[ -n "${exported[$var]:-}" ]]; then
        add_finding "INFO" "runtime:$rel" "$file" "${assigned_line[$var]}" "VAR014" "Exported variable '$var' is not used in this script; verify it is needed by child processes."
      else
        add_finding "WARN" "runtime:$rel" "$file" "${assigned_line[$var]}" "VAR015" "Variable '$var' is assigned but not used in this script."
      fi
    fi
  done
}

check_inline_cli_commands() {
  local code="$1" file="$2" line="$3" phase="$4"
  local commands="${code#*--commands=}"
  commands="${commands%\"}"
  commands="${commands#\"}"
  commands="${commands%\'}"
  commands="${commands#\'}"
  check_cli_line "$commands" "$file" "$line" "$phase" "inline"
}

count_char() {
  local text="$1" char="$2"
  awk -v ch="$char" '{
    for (i=1; i<=length($0); i++) {
      if (substr($0,i,1) == ch) n++
    }
  } END { print n+0 }' <<< "$text"
}

extract_cli_value() {
  local key="$1" text="$2"
  sed -n "s/.*$key[[:space:]]*=[[:space:]]*['\"]\\{0,1\\}\\([^,'\")[:space:]]*\\).*/\\1/p" <<< "$text" | head -n 1
}

scan_ecs_env_expressions() {
  local text="$1" file="$2" line="$3" phase="$4" source="$5"
  local ref name kind
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    name="${ref%%|*}"
    kind="${ref#*|}"
    [[ -z "$name" ]] && continue
    if is_standard_env_var "$name"; then
      continue
    fi
    if [[ "$kind" == "wildfly-env-expression" ]]; then
      add_ecs_env_record "$name" "required_or_expected" "$source env expression" "$file" "$line" "" "" "WildFly/JBoss CLI references this environment variable with an expression. Provide it from the ECS task definition when the CLI runs at container startup." "$text"
    else
      add_ecs_env_record "$name" "possible" "$source expression" "$file" "$line" "" "" "Configuration contains a variable expression. If it is resolved from the process environment, provide it from the ECS task definition." "$text"
    fi
  done < <(printf '%s\n' "$text" | extract_env_expr_refs)
}

extract_cli_subsystem() {
  local code="$1"
  sed -n 's#.*\/subsystem=\([^/:,)]*\).*#\1#p' <<< "$code" | head -n 1
}

extract_cli_resource() {
  local code="$1" path
  path="${code%%:*}"
  path="${path##*/}"
  [[ "$path" == subsystem=* ]] && path=""
  printf '%s' "$path"
}

extract_cli_operation() {
  local code="$1" op
  op="${code#*:}"
  op="${op%%(*}"
  op="${op%% *}"
  printf '%s' "$op"
}

extract_cli_args_text() {
  local code="$1"
  if [[ "$code" == *"("* && "$code" == *")"* ]]; then
    local args="${code#*(}"
    args="${args%)*}"
    printf '%s' "$args"
  fi
}

split_cli_arg_pairs() {
  awk '
  {
    depth=0; in_string=0; quote=""; token="";
    for (i=1; i<=length($0); i++) {
      c=substr($0,i,1);
      if (in_string) {
        token=token c;
        if (c==quote) in_string=0;
        continue;
      }
      if (c=="\"" || c=="\047") {
        in_string=1; quote=c; token=token c; continue;
      }
      if (c=="(" || c=="[" || c=="{") depth++;
      if (c==")" || c=="]" || c=="}") depth--;
      if (c=="," && depth==0) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", token);
        if (token!="") print token;
        token="";
      } else {
        token=token c;
      }
    }
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", token);
    if (token!="") print token;
  }'
}

clean_cli_value() {
  local value="$1"
  value="$(trim "$value")"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

jboss_setting_description() {
  local subsystem="$1" key="$2"
  case "$subsystem:$key" in
    datasources:jndi-name) printf 'JNDI name that applications use to look up the datasource.' ;;
    datasources:driver-name) printf 'Datasource driver name registered in the WildFly datasource subsystem.' ;;
    datasources:driver-module-name) printf 'JBoss module name that provides the JDBC driver.' ;;
    datasources:driver-class-name) printf 'JDBC driver implementation class.' ;;
    datasources:driver-xa-datasource-class-name) printf 'XA datasource implementation class for XA transactions.' ;;
    datasources:connection-url) printf 'JDBC connection URL used by the datasource.' ;;
    datasources:user-name) printf 'Database username configured for the datasource.' ;;
    datasources:password) printf 'Database password or expression used by the datasource.' ;;
    datasources:min-pool-size) printf 'Minimum number of physical database connections kept in the pool.' ;;
    datasources:max-pool-size) printf 'Maximum number of physical database connections allowed in the pool.' ;;
    datasources:blocking-timeout-wait-millis) printf 'Maximum wait time for a connection from the pool before failing.' ;;
    datasources:idle-timeout-minutes) printf 'How long idle connections can remain in the pool before being closed.' ;;
    datasources:prepared-statements-cache-size) printf 'Number of prepared statements cached per connection.' ;;
    datasources:validate-on-match) printf 'Whether to validate a connection every time it is checked out from the pool.' ;;
    datasources:background-validation) printf 'Whether idle connections are validated in the background.' ;;
    datasources:background-validation-millis) printf 'Interval for background connection validation.' ;;
    datasources:check-valid-connection-sql) printf 'SQL statement used to validate database connections.' ;;
    datasources:pool-prefill) printf 'Whether to create the minimum pool connections during startup.' ;;
    datasources:statistics-enabled) printf 'Whether datasource runtime statistics are enabled.' ;;
    datasources:enabled) printf 'Whether the datasource or JDBC driver is enabled.' ;;
    undertow:proxy-address-forwarding) printf 'Whether Undertow trusts proxy forwarding headers for client address and scheme.' ;;
    undertow:max-post-size) printf 'Maximum HTTP request body size accepted by Undertow.' ;;
    undertow:buffer-cache) printf 'Undertow buffer cache reference used by handlers.' ;;
    logging:level) printf 'Logging level for the selected logger or handler.' ;;
    transactions:default-timeout) printf 'Default transaction timeout in seconds.' ;;
    deployment-scanner:auto-deploy-zipped) printf 'Whether zipped deployments are auto-deployed by the deployment scanner.' ;;
    deployment-scanner:auto-deploy-exploded) printf 'Whether exploded deployments are auto-deployed by the deployment scanner.' ;;
    deployment-scanner:scan-enabled) printf 'Whether deployment scanning is enabled.' ;;
    *) printf 'WildFly/JBoss CLI subsystem attribute.' ;;
  esac
}

jboss_setting_recommendation() {
  local subsystem="$1" key="$2" resource="$3"
  case "$subsystem:$key" in
    datasources:jndi-name) printf 'Use java:/jdbc/<name> or java:jboss/datasources/<name> consistently with application lookup names.' ;;
    datasources:driver-name) printf 'Must match an installed JDBC driver name.' ;;
    datasources:driver-module-name) printf 'Use the module that contains the JDBC driver, for example org.postgresql, com.oracle, com.mysql.' ;;
    datasources:driver-class-name) printf 'Use the vendor driver class, for example org.postgresql.Driver, oracle.jdbc.OracleDriver, com.mysql.cj.jdbc.Driver.' ;;
    datasources:connection-url) printf 'Externalize environment-specific host, port, database, and credentials; avoid hard-coded production secrets.' ;;
    datasources:user-name|datasources:password) printf 'Use credential store, environment expression, or secret injection instead of plain literal secrets.' ;;
    datasources:min-pool-size) printf '0-5 for typical containers; keep <= max-pool-size and size from load tests.' ;;
    datasources:max-pool-size) printf '20-100 for many services, capped by database capacity and replica count.' ;;
    datasources:blocking-timeout-wait-millis) printf '30000-60000 milliseconds.' ;;
    datasources:idle-timeout-minutes) printf '5-15 minutes.' ;;
    datasources:prepared-statements-cache-size) printf '32-100 when prepared statement caching is beneficial.' ;;
    datasources:validate-on-match) printf 'false when background-validation=true; true can be acceptable for small pools needing strict checkout validation.' ;;
    datasources:background-validation) printf 'true for production pools unless validate-on-match is intentionally used.' ;;
    datasources:background-validation-millis) printf '30000-60000 milliseconds.' ;;
    datasources:check-valid-connection-sql) printf 'Use a cheap vendor-specific validation query, for example SELECT 1.' ;;
    datasources:pool-prefill) printf 'false unless startup must eagerly open min-pool-size connections.' ;;
    datasources:statistics-enabled) printf 'false by default; enable when metrics are required and overhead is acceptable.' ;;
    datasources:enabled) printf 'true for active datasources/drivers.' ;;
    undertow:proxy-address-forwarding) printf 'true only when running behind a trusted reverse proxy that sets forwarding headers.' ;;
    undertow:max-post-size) printf 'Set explicitly to the smallest value that supports expected uploads/request bodies.' ;;
    logging:level) printf 'INFO for production by default; DEBUG/TRACE only temporarily.' ;;
    transactions:default-timeout) printf '300-600 seconds unless application transaction requirements differ.' ;;
    deployment-scanner:auto-deploy-zipped|deployment-scanner:auto-deploy-exploded|deployment-scanner:scan-enabled) printf 'false in immutable container images; deploy during build or startup script instead.' ;;
    *) printf 'Review against the WildFly version documentation and workload requirements.' ;;
  esac
}

jboss_setting_distance() {
  local subsystem="$1" key="$2" value="$3"
  local lval
  lval="$(lower "$value")"
  case "$subsystem:$key" in
    datasources:jndi-name)
      [[ "$value" == java:/* || "$value" == java:jboss/* ]] && printf 'matches naming convention' || printf 'does not match java:/ or java:jboss/ naming convention'
      ;;
    datasources:min-pool-size)
      numeric_range_distance "$value" 0 5 ''
      ;;
    datasources:max-pool-size)
      numeric_range_distance "$value" 20 100 ''
      ;;
    datasources:blocking-timeout-wait-millis)
      numeric_range_distance "$value" 30000 60000 ' ms'
      ;;
    datasources:idle-timeout-minutes)
      numeric_range_distance "$value" 5 15 ' min'
      ;;
    datasources:prepared-statements-cache-size)
      numeric_range_distance "$value" 32 100 ''
      ;;
    datasources:background-validation)
      bool_distance "$value" "true"
      ;;
    datasources:background-validation-millis)
      numeric_range_distance "$value" 30000 60000 ' ms'
      ;;
    datasources:pool-prefill|datasources:statistics-enabled)
      bool_distance "$value" "false"
      ;;
    datasources:enabled)
      bool_distance "$value" "true"
      ;;
    logging:level)
      case "$lval" in
        info) printf 'matches recommended production default' ;;
        warn|error) printf 'more restrictive than INFO; verify observability requirements' ;;
        debug|trace|all) printf 'more verbose than recommended production default' ;;
        *) printf 'context-dependent' ;;
      esac
      ;;
    transactions:default-timeout)
      numeric_range_distance "$value" 300 600 ' sec'
      ;;
    deployment-scanner:auto-deploy-zipped|deployment-scanner:auto-deploy-exploded|deployment-scanner:scan-enabled)
      bool_distance "$value" "false"
      ;;
    *) printf 'N/A or context-dependent' ;;
  esac
}

jboss_setting_severity() {
  local subsystem="$1" key="$2" value="$3"
  local lval
  lval="$(lower "$value")"
  case "$subsystem:$key" in
    datasources:jndi-name)
      [[ "$value" == java:/* || "$value" == java:jboss/* ]] && printf 'OK' || printf 'WARN'
      ;;
    datasources:min-pool-size)
      numeric_range_severity "$value" 0 5
      ;;
    datasources:max-pool-size)
      numeric_range_severity "$value" 20 100
      ;;
    datasources:blocking-timeout-wait-millis)
      numeric_range_severity "$value" 30000 60000
      ;;
    datasources:idle-timeout-minutes)
      numeric_range_severity "$value" 5 15
      ;;
    datasources:prepared-statements-cache-size)
      numeric_range_severity "$value" 32 100
      ;;
    datasources:background-validation)
      bool_severity "$value" "true"
      ;;
    datasources:background-validation-millis)
      numeric_range_severity "$value" 30000 60000
      ;;
    datasources:pool-prefill|datasources:statistics-enabled)
      bool_severity "$value" "false"
      ;;
    datasources:enabled)
      bool_severity "$value" "true"
      ;;
    logging:level)
      case "$lval" in
        debug|trace|all) printf 'WARN' ;;
        *) printf 'INFO' ;;
      esac
      ;;
    transactions:default-timeout)
      numeric_range_severity "$value" 300 600
      ;;
    deployment-scanner:auto-deploy-zipped|deployment-scanner:auto-deploy-exploded|deployment-scanner:scan-enabled)
      bool_severity "$value" "false"
      ;;
    *) printf 'INFO' ;;
  esac
}

record_jboss_cli_setting() {
  local subsystem="$1" resource="$2" operation="$3" key="$4" value="$5" file="$6" line="$7" phase="$8" evidence="$9"
  local component setting
  [[ -z "$subsystem" || -z "$key" ]] && return 0
  component="$subsystem"
  [[ -n "$resource" ]] && component="$component/$resource"
  setting="$subsystem.$key"
  [[ -n "$resource" ]] && setting="$subsystem.$resource.$key"
  add_config_record "WildFly/JBoss CLI" "$component" "$setting" "$(jboss_setting_description "$subsystem" "$key")" "$value" "$(jboss_setting_recommendation "$subsystem" "$key" "$resource")" "$(jboss_setting_distance "$subsystem" "$key" "$value")" "$(jboss_setting_severity "$subsystem" "$key" "$value")" "$phase" "$file" "$line" "$evidence"
}

scan_jboss_cli_settings() {
  local code="$1" file="$2" line="$3" phase="$4"
  local subsystem resource operation args pair key value write_name write_value
  subsystem="$(extract_cli_subsystem "$code")"
  [[ -z "$subsystem" ]] && return 0
  resource="$(extract_cli_resource "$code")"
  operation="$(extract_cli_operation "$code")"
  args="$(extract_cli_args_text "$code")"
  [[ -z "$args" ]] && return 0

  while IFS= read -r pair; do
    key="$(trim "${pair%%=*}")"
    value="$(clean_cli_value "${pair#*=}")"
    [[ -z "$key" || "$pair" != *=* ]] && continue
    if [[ "$operation" == "write-attribute" ]]; then
      [[ "$key" == "name" ]] && write_name="$value"
      [[ "$key" == "value" ]] && write_value="$value"
    else
      record_jboss_cli_setting "$subsystem" "$resource" "$operation" "$key" "$value" "$file" "$line" "$phase" "$code"
    fi
  done < <(printf '%s\n' "$args" | split_cli_arg_pairs)

  if [[ "$operation" == "write-attribute" && -n "$write_name" ]]; then
    record_jboss_cli_setting "$subsystem" "$resource" "$operation" "$write_name" "$write_value" "$file" "$line" "$phase" "$code"
  fi
}

check_jndi_value() {
  local value="$1" file="$2" line="$3" phase="$4" source="$5"
  [[ -z "$value" ]] && return 0
  if [[ "$value" != java:/* && "$value" != java:jboss/* ]]; then
    add_finding "WARN" "$phase" "$file" "$line" "JNDI001" "$source JNDI value '$value' does not start with java:/ or java:jboss/."
  fi
  if [[ "$value" == *'$'* ]]; then
    add_finding "WARN" "$phase" "$file" "$line" "JNDI002" "$source JNDI value '$value' contains a variable; ensure it has a safe default or required external value."
  fi
  local key="$file:$value"
  if [[ -n "${CLI_JNDI_SEEN[$key]:-}" ]]; then
    add_finding "WARN" "$phase" "$file" "$line" "JNDI003" "Duplicate JNDI value '$value' also appears on line ${CLI_JNDI_SEEN[$key]}."
  else
    CLI_JNDI_SEEN[$key]="$line"
  fi
}

check_cli_line() {
  local line_text="$1" file="$2" line="$3" phase="$4" cli_name="$5"
  local code jndi binding_type dquotes lpar rpar lbrace rbrace lbrack rbrack
  local driver_name driver_module driver_class xa_class driver_vendor driver_version driver_label
  local re_type_param='(^|[,(]|[[:space:]])type[[:space:]]*='
  local re_value_param='(^|[,(]|[[:space:]])value[[:space:]]*='
  local re_lookup_param='(^|[,(]|[[:space:]])lookup[[:space:]]*='
  code="$(trim "${line_text%%#*}")"
  [[ -z "$code" ]] && return 0
  scan_ecs_env_expressions "$code" "$file" "$line" "$phase" "WildFly/JBoss CLI"
  scan_jboss_cli_settings "$code" "$file" "$line" "$phase"

  dquotes=$(awk '{
    n=0; esc=0;
    for (i=1; i<=length($0); i++) {
      c=substr($0,i,1);
      if (esc) { esc=0; continue; }
      if (c=="\\") { esc=1; continue; }
      if (c=="\"") n++;
    }
    print n;
  }' <<< "$code")
  if (( dquotes % 2 == 1 )); then
    add_finding "ERROR" "$phase" "$file" "$line" "CLI003" "$cli_name has an unmatched double quote."
  fi

  lpar=$(count_char "$code" "("); rpar=$(count_char "$code" ")")
  lbrace=$(count_char "$code" "{"); rbrace=$(count_char "$code" "}")
  lbrack=$(count_char "$code" "["); rbrack=$(count_char "$code" "]")
  if (( lpar != rpar || lbrace != rbrace || lbrack != rbrack )); then
    add_finding "ERROR" "$phase" "$file" "$line" "CLI004" "$cli_name has unbalanced (), {}, or [] delimiters."
  fi

  case "$code" in
    /*|:*|if\ *|else|end-if|try|catch|finally|end-try|batch|run-batch|discard-batch|embed-server*|stop-embedded-server*|connect*|cd\ *|ls*|echo\ *|quit|reload*)
      ;;
    *)
      add_finding "INFO" "$phase" "$file" "$line" "CLI005" "$cli_name line does not look like a standard jboss-cli command; verify syntax."
      ;;
  esac

  if [[ "$code" == *"jndi-name"* ]]; then
    jndi="$(extract_cli_value "jndi-name" "$code")"
    check_jndi_value "$jndi" "$file" "$line" "$phase" "jboss-cli"
  fi

  driver_name="$(extract_cli_value "driver-name" "$code")"
  driver_module="$(extract_cli_value "driver-module-name" "$code")"
  driver_class="$(extract_cli_value "driver-class-name" "$code")"
  xa_class="$(extract_cli_value "driver-xa-datasource-class-name" "$code")"
  if [[ -n "$driver_name" || -n "$driver_module" || -n "$driver_class" || -n "$xa_class" ]]; then
    driver_label="${driver_name:-${driver_module:-${driver_class:-$xa_class}}}"
    driver_vendor="$(infer_db_driver_vendor "$driver_label $driver_module $driver_class $xa_class")"
    [[ -z "$driver_vendor" ]] && driver_vendor="$driver_label"
    driver_version="$(infer_version_from_filename "$driver_label")"
    add_software_record "$driver_vendor" "database-driver-cli-config" "$driver_version" "WildFly jboss-cli datasource/driver config" "$phase" "$file" "$line" "$code" "driver-name=$driver_name; driver-module-name=$driver_module; driver-class-name=$driver_class; driver-xa-datasource-class-name=$xa_class"
  fi

  if [[ "$code" == *"/subsystem=naming/binding="* || "$code" == *"binding="*":add("* ]]; then
    binding_type="$(extract_cli_value "binding-type" "$code")"
    if [[ -z "$binding_type" ]]; then
      add_finding "WARN" "$phase" "$file" "$line" "JNDI004" "Naming binding add operation has no binding-type."
    elif [[ "$binding_type" == "simple" ]]; then
      [[ "$code" =~ $re_type_param ]] || add_finding "WARN" "$phase" "$file" "$line" "JNDI005" "JNDI simple binding is missing type=."
      [[ "$code" =~ $re_value_param ]] || add_finding "WARN" "$phase" "$file" "$line" "JNDI006" "JNDI simple binding is missing value=."
    elif [[ "$binding_type" == "lookup" ]]; then
      [[ "$code" =~ $re_lookup_param ]] || add_finding "WARN" "$phase" "$file" "$line" "JNDI007" "JNDI lookup binding is missing lookup=."
    fi
  fi

  if [[ "$code" == *"data-source"*":add("* || "$code" == data-source\ add* || "$code" == *"xa-data-source"*":add("* ]]; then
    [[ "$code" == *"jndi-name"* ]] || add_finding "WARN" "$phase" "$file" "$line" "JNDI008" "Datasource add operation has no jndi-name=."
  fi
}

scan_cli_file() {
  local rel="$1" reason="$2"
  local file="$CONTEXT_DIR/$rel"
  [[ -f "$file" || -L "$file" ]] || return 0
  progress_log "CHECK" "Scanning WildFly CLI file: $rel ($reason)"

  local line no=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    no=$((no + 1))
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"
    check_cli_line "$line" "$file" "$no" "runtime:jboss-cli" "$rel"
  done < "$file"
}

discover_cli_files_by_extension() {
  local full rel
  while IFS= read -r -d '' full; do
    rel="$(rel_to_context "$full")"
    if [[ -n "${REFERENCED_CONTEXT[$rel]:-}" ]]; then
      add_cli_file "$rel" "referenced build-context CLI file"
    fi
  done < <(find "$CONTEXT_DIR" -path '*/.git' -prune -o -type f -iname '*.cli' -print0)
}

scan_all_shells() {
  local progress=1 rel
  progress_log "CHECK" "Resolving and scanning entrypoint/called shell scripts"
  while (( progress )); do
    progress=0
    for rel in "${!SHELL_FILES[@]}"; do
      if [[ "${SHELL_FILES[$rel]}" == "1" ]]; then
        SHELL_FILES["$rel"]="scanned"
        scan_shell_file "$rel" "${SHELL_REASON[$rel]}"
        progress=1
      fi
    done
  done
}

scan_all_cli() {
  local rel
  progress_log "CHECK" "Resolving and scanning WildFly jboss-cli files"
  discover_cli_files_by_extension
  for rel in "${!CLI_FILES[@]}"; do
    scan_cli_file "$rel" "${CLI_REASON[$rel]}"
  done
}

run_runtime_probe_command() {
  local image="$1" tool="$2" command="$3" output rc sev message
  progress_log "PROBE" "Running Docker runtime probe for $tool"
  docker_capture run --rm --entrypoint /bin/sh "$image" -c "$command"
  rc=$?
  output="$DOCKER_CAPTURE_OUTPUT"
  if (( rc != 0 )) && docker_permission_sudo_failed; then
    add_finding "WARN" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP008" "$(docker_permission_warning_text)"
    return 0
  fi
  output="$(compact_output "$output")"
  case "$tool" in
    ksh)
      if (( rc == 0 )); then
        add_finding "INFO" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP003" "Docker runtime probe succeeded: ksh is executable. Output: $output"
        add_software_record "ksh" "runtime-probe-executable" "" "docker run probe" "runtime-probe" "$DOCKERFILE_PATH" "-" "$output" "ksh was executed inside the built image."
      else
        sev="WARN"
        runtime_probe_expected_ksh && sev="ERROR"
        message="Docker runtime probe failed: ksh is not executable or /bin/sh probe command failed. Output: $output"
        add_finding "$sev" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP004" "$message"
      fi
      ;;
    java)
      if (( rc == 0 )); then
        add_finding "INFO" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP005" "Docker runtime probe succeeded: java -version is executable. Output: $output"
        add_software_record "Java" "runtime-probe-executable" "" "docker run java -version" "runtime-probe" "$DOCKERFILE_PATH" "-" "$output" "java -version was executed inside the built image."
      else
        sev="WARN"
        runtime_probe_expected_java && sev="ERROR"
        message="Docker runtime probe failed: java is not executable or /bin/sh probe command failed. Output: $output"
        add_finding "$sev" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP006" "$message"
      fi
      ;;
  esac
}

run_runtime_probe() {
  (( RUNTIME_PROBE_ENABLED )) || return 0
  local image build_output info_output cleanup_output auto_image=0
  if [[ -z "$RUNTIME_PROBE_IMAGE" ]]; then
    RUNTIME_PROBE_IMAGE="docker-context-checker-probe:$(date '+%Y%m%d%H%M%S')-$$"
    auto_image=1
  fi
  image="$RUNTIME_PROBE_IMAGE"
  RUNTIME_PROBE_EFFECTIVE_IMAGE="$image"

  progress_log "PROBE" "Checking Docker CLI and daemon"
  if ! command -v docker >/dev/null 2>&1; then
    add_finding "ERROR" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP001" "Docker runtime probe was requested, but docker command was not found in PATH."
    return 0
  fi
  if ! docker_capture info; then
    info_output="$DOCKER_CAPTURE_OUTPUT"
    if docker_permission_sudo_failed; then
      add_finding "WARN" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP008" "$(docker_permission_warning_text)"
      return 0
    fi
    add_finding "ERROR" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP001" "Docker runtime probe was requested, but Docker daemon is not available. Output: $(compact_output "$info_output")"
    return 0
  fi

  progress_log "PROBE" "Building Docker image for runtime probe: $image"
  if ! docker_capture build "${RUNTIME_PROBE_BUILD_OPTIONS[@]}" -f "$DOCKERFILE_PATH" -t "$image" "$CONTEXT_DIR"; then
    build_output="$DOCKER_CAPTURE_OUTPUT"
    if docker_permission_sudo_failed; then
      add_finding "WARN" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP008" "$(docker_permission_warning_text)"
      return 0
    fi
    add_finding "ERROR" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP002" "Docker runtime probe image build failed. Output: $(compact_output "$build_output")"
    return 0
  fi

  run_runtime_probe_command "$image" "ksh" 'set -e; command -v ksh; ksh -c "print OK_KSH"; (ksh --version 2>&1 || true)'
  run_runtime_probe_command "$image" "java" 'set -e; command -v java; java -version'

  if (( ! RUNTIME_PROBE_KEEP_IMAGE && auto_image && ! RUNTIME_PROBE_IMAGE_CUSTOM )); then
    progress_log "PROBE" "Removing temporary runtime probe image: $image"
    if ! docker_capture image rm "$image"; then
      cleanup_output="$DOCKER_CAPTURE_OUTPUT"
      if docker_permission_sudo_failed; then
        add_finding "WARN" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP008" "$(docker_permission_warning_text)"
        return 0
      fi
      add_finding "INFO" "runtime-probe" "$DOCKERFILE_PATH" "-" "RTP007" "Temporary runtime probe image could not be removed automatically. Output: $(compact_output "$cleanup_output")"
    fi
  fi
}

extract_eap_deployed_wars() {
  awk '
  {
    line=$0
    while (match(line, /[A-Za-z0-9_.+@%:=\/-]+\.war/)) {
      war=substr(line, RSTART, RLENGTH)
      gsub(/^deployment\./, "", war)
      if (!seen[war]++) print war
      line=substr(line, RSTART + RLENGTH)
    }
  }'
}

extract_eap_matching_lines() {
  local pattern="$1"
  grep -Ei "$pattern" | head -n 8 | sed 's/^[[:space:]]*//'
}

eap_log_has_startup_success() {
  grep -Eqi 'WFLYSRV0025:.*(JBoss EAP|WildFly|started in|Started [0-9]+ of [0-9]+ services)|JBoss EAP .*started in|WildFly .*started in|Started [0-9]+ of [0-9]+ services'
}

eap_log_has_deploy_success() {
  grep -Eqi 'WFLYSRV0010: Deployed ".*\.war"|Deployed ".*\.war"|Deployment ".*\.war" successfully|Successfully deployed .*\.war'
}

eap_log_has_failure() {
  grep -Eqi 'WFLYSRV0026|WFLYSRV0153|WFLYCTL0180|WFLYCTL0080|WFLYSRV0087|failed to .*deploy|Deployment .*failed|ERROR .*\.war|Caused by:|Exception'
}

eap_log_has_eap81() {
  grep -Eqi 'JBoss EAP[^0-9]*8\.1|EAP[^0-9]*8\.1'
}

resolve_external_base_for_stage() {
  local stage="$1" base base_l next guard=0
  while (( stage >= 0 && stage <= FINAL_STAGE )); do
    base="${STAGE_BASE[$stage]:-}"
    [[ -z "$base" ]] && return 1
    [[ "$base" == *'$'* || "$base" == *'${'* ]] && return 1

    base_l="$(lower "$base")"
    next="${STAGE_BY_NAME[$base_l]:-}"
    if [[ -n "$next" && "$next" =~ ^[0-9]+$ && "$next" != "$stage" ]]; then
      stage="$next"
      guard=$((guard + 1))
      (( guard <= FINAL_STAGE + 1 )) || return 1
      continue
    fi

    printf '%s' "$base"
    return 0
  done
  return 1
}

run_eap_startup_probe() {
  (( EAP_STARTUP_PROBE_ENABLED )) || return 0
  local image container build_output info_output run_output logs cleanup_output auto_image=0 auto_container=0
  local start deadline now startup_success=0 deploy_success=0 failure_seen=0 eap81_seen=0 exited=0 exit_status=""
  local wars war_list startup_lines deploy_lines failure_lines permission_probe_blocked=0
  local -a run_cmd=()

  case "$EAP_STARTUP_TARGET" in
    build)
      if [[ -z "$EAP_STARTUP_IMAGE" ]]; then
        EAP_STARTUP_IMAGE="docker-context-checker-eap-probe:$(date '+%Y%m%d%H%M%S')-$$"
        auto_image=1
      fi
      image="$EAP_STARTUP_IMAGE"
      EAP_STARTUP_EFFECTIVE_MODE="build"
      ;;
    from)
      if ! image="$(resolve_external_base_for_stage "$FINAL_STAGE")"; then
        add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "${STAGE_LINE[$FINAL_STAGE]:-1}" "EAP014" "JBoss EAP startup probe target=from could not resolve a runnable external image from the final FROM instruction: ${FINAL_BASE:-unknown}."
        return 0
      fi
      EAP_STARTUP_EFFECTIVE_MODE="from"
      add_finding "INFO" "eap-startup-probe" "$DOCKERFILE_PATH" "${STAGE_LINE[$FINAL_STAGE]:-1}" "EAP015" "JBoss EAP startup probe will run the Dockerfile FROM base image directly; docker build is skipped. Image: $image"
      ;;
    image)
      if [[ -z "$EAP_STARTUP_RUN_IMAGE" && -n "$EAP_STARTUP_IMAGE" ]]; then
        EAP_STARTUP_RUN_IMAGE="$EAP_STARTUP_IMAGE"
      fi
      if [[ -z "$EAP_STARTUP_RUN_IMAGE" ]]; then
        add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP014" "JBoss EAP startup probe target=image requires --eap-startup-run-image IMAGE."
        return 0
      fi
      image="$EAP_STARTUP_RUN_IMAGE"
      EAP_STARTUP_EFFECTIVE_MODE="image"
      add_finding "INFO" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP015" "JBoss EAP startup probe will run an existing image directly; docker build is skipped. Image: $image"
      ;;
    *)
      add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP014" "Unsupported JBoss EAP startup probe target mode: $EAP_STARTUP_TARGET."
      return 0
      ;;
  esac

  if [[ -z "$EAP_STARTUP_CONTAINER" ]]; then
    EAP_STARTUP_CONTAINER="docker-context-checker-eap-probe-$(date '+%Y%m%d%H%M%S')-$$"
    auto_container=1
  fi
  container="$EAP_STARTUP_CONTAINER"
  EAP_STARTUP_EFFECTIVE_IMAGE="$image"
  EAP_STARTUP_EFFECTIVE_CONTAINER="$container"

  progress_log "EAP-PROBE" "Checking Docker CLI and daemon"
  if ! command -v docker >/dev/null 2>&1; then
    add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP001" "JBoss EAP startup probe was requested, but docker command was not found in PATH."
    return 0
  fi
  if ! docker_capture info; then
    info_output="$DOCKER_CAPTURE_OUTPUT"
    if docker_permission_sudo_failed; then
      add_finding "WARN" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP013" "$(docker_permission_warning_text)"
      return 0
    fi
    add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP001" "JBoss EAP startup probe was requested, but Docker daemon is not available. Output: $(compact_output "$info_output")"
    return 0
  fi

  if [[ "$EAP_STARTUP_EFFECTIVE_MODE" == "build" ]]; then
    progress_log "EAP-PROBE" "Building Docker image for JBoss EAP startup probe: $image"
    if ! docker_capture build "${EAP_STARTUP_BUILD_OPTIONS[@]}" -f "$DOCKERFILE_PATH" -t "$image" "$CONTEXT_DIR"; then
      build_output="$DOCKER_CAPTURE_OUTPUT"
      if docker_permission_sudo_failed; then
        add_finding "WARN" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP013" "$(docker_permission_warning_text)"
        return 0
      fi
      add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP002" "JBoss EAP startup probe image build failed. Output: $(compact_output "$build_output")"
      return 0
    fi
  else
    progress_log "EAP-PROBE" "Skipping docker build; using $EAP_STARTUP_EFFECTIVE_MODE image for JBoss EAP startup probe: $image"
  fi

  progress_log "EAP-PROBE" "Starting container for JBoss EAP log probe: $container"
  run_cmd=(run -d --name "$container" "${EAP_STARTUP_RUN_OPTIONS[@]}" "$image")
  if [[ -n "$EAP_STARTUP_COMMAND" ]]; then
    run_cmd+=("/bin/sh" "-lc" "$EAP_STARTUP_COMMAND")
  fi
  if ! docker_capture "${run_cmd[@]}"; then
    run_output="$DOCKER_CAPTURE_OUTPUT"
    if docker_permission_sudo_failed; then
      add_finding "WARN" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP013" "$(docker_permission_warning_text)"
      return 0
    fi
    add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP003" "JBoss EAP startup probe container could not be started. Output: $(compact_output "$run_output")"
    return 0
  fi

  start=$(date +%s)
  deadline=$((start + EAP_STARTUP_TIMEOUT))
  logs=""
  while :; do
    if docker_capture logs "$container"; then
      logs="$DOCKER_CAPTURE_OUTPUT"
    else
      logs="$DOCKER_CAPTURE_OUTPUT"
      if docker_permission_sudo_failed; then
        add_finding "WARN" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP013" "$(docker_permission_warning_text)"
        permission_probe_blocked=1
        break
      fi
    fi
    if printf '%s\n' "$logs" | eap_log_has_startup_success; then
      startup_success=1
    fi
    if printf '%s\n' "$logs" | eap_log_has_deploy_success; then
      deploy_success=1
    fi
    if printf '%s\n' "$logs" | eap_log_has_failure; then
      failure_seen=1
    fi
    if printf '%s\n' "$logs" | eap_log_has_eap81; then
      eap81_seen=1
    fi
    if (( startup_success && deploy_success )); then
      break
    fi
    if docker_capture inspect -f '{{.State.Status}}:{{.State.ExitCode}}' "$container"; then
      exit_status="$DOCKER_CAPTURE_OUTPUT"
    else
      exit_status=""
      if docker_permission_sudo_failed; then
        add_finding "WARN" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP013" "$(docker_permission_warning_text)"
        permission_probe_blocked=1
        break
      fi
    fi
    if [[ "$exit_status" == exited:* || "$exit_status" == dead:* ]]; then
      exited=1
      break
    fi
    now=$(date +%s)
    (( now >= deadline )) && break
    sleep 2
  done

  war_list="$(printf '%s\n' "$logs" | extract_eap_deployed_wars | paste -sd ',' - | sed 's/,/, /g')"
  startup_lines="$(printf '%s\n' "$logs" | extract_eap_matching_lines 'WFLYSRV0025:.*(started|JBoss EAP|WildFly)|Started [0-9]+ of [0-9]+ services')"
  deploy_lines="$(printf '%s\n' "$logs" | extract_eap_matching_lines 'WFLYSRV0010: Deployed ".*\.war"|Deployed ".*\.war"|Deployment ".*\.war" successfully|Successfully deployed .*\.war')"
  failure_lines="$(printf '%s\n' "$logs" | extract_eap_matching_lines 'WFLYSRV0026|WFLYSRV0153|WFLYCTL0180|WFLYCTL0080|WFLYSRV0087|failed to .*deploy|Deployment .*failed|ERROR .*\.war|Caused by:|Exception')"

  if [[ -n "$war_list" ]]; then
    add_finding "INFO" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP010" "Detected deployed WAR file(s) from JBoss EAP startup logs: $war_list"
    while IFS= read -r wars; do
      [[ -z "$wars" ]] && continue
      add_software_record "$wars" "jboss-eap-deployed-war" "" "docker startup log probe" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "$wars" "WAR deployment detected from JBoss EAP startup logs."
    done < <(printf '%s\n' "$logs" | extract_eap_deployed_wars)
  fi

  if (( permission_probe_blocked )); then
    :
  elif (( startup_success && deploy_success )); then
    add_finding "INFO" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP004" "JBoss EAP startup probe succeeded: startup success and WAR deployment success logs were found. WARs: ${war_list:-'(none parsed)'}. Startup log: $(compact_output "$startup_lines") Deployment log: $(compact_output "$deploy_lines")"
    if (( ! eap81_seen )); then
      add_finding "WARN" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP012" "JBoss EAP startup succeeded, but the logs did not clearly identify JBoss EAP 8.1. Verify the image version. Startup log: $(compact_output "$startup_lines")"
    fi
    if (( failure_seen )); then
      add_finding "WARN" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP007" "Failure-looking lines were also found in JBoss EAP startup logs. Review whether they are harmless. Lines: $(compact_output "$failure_lines")"
    fi
  else
    if (( failure_seen )); then
      add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP007" "Failure-looking lines were found in JBoss EAP startup logs. Lines: $(compact_output "$failure_lines")"
    fi
    if (( startup_success && ! deploy_success )); then
      add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP005" "JBoss EAP startup success log was found, but WAR deployment success log was not found before timeout. Startup log: $(compact_output "$startup_lines")"
    elif (( deploy_success && ! startup_success )); then
      add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP006" "WAR deployment success log was found, but JBoss EAP startup success log was not found before timeout. Deployment log: $(compact_output "$deploy_lines")"
    elif (( exited )); then
      add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP009" "JBoss EAP startup probe container exited before startup/deployment success was confirmed. Container state: $exit_status Log tail: $(compact_output "$(printf '%s\n' "$logs" | tail -n 30)")"
    else
      add_finding "ERROR" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP008" "Timed out after ${EAP_STARTUP_TIMEOUT}s waiting for both JBoss EAP startup success and WAR deployment success logs. Log tail: $(compact_output "$(printf '%s\n' "$logs" | tail -n 30)")"
    fi
  fi

  if (( ! EAP_STARTUP_KEEP_CONTAINER && auto_container && ! EAP_STARTUP_CONTAINER_CUSTOM )); then
    progress_log "EAP-PROBE" "Removing JBoss EAP startup probe container: $container"
    if ! docker_capture rm -f "$container"; then
      cleanup_output="$DOCKER_CAPTURE_OUTPUT"
      if docker_permission_sudo_failed; then
        add_finding "WARN" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP013" "$(docker_permission_warning_text)"
      fi
      add_finding "INFO" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP011" "Temporary JBoss EAP probe container could not be removed automatically. Output: $(compact_output "$cleanup_output")"
    fi
  fi
  if [[ "$EAP_STARTUP_EFFECTIVE_MODE" == "build" ]] && (( ! EAP_STARTUP_KEEP_IMAGE && auto_image && ! EAP_STARTUP_IMAGE_CUSTOM )); then
    progress_log "EAP-PROBE" "Removing JBoss EAP startup probe image: $image"
    if ! docker_capture image rm "$image"; then
      cleanup_output="$DOCKER_CAPTURE_OUTPUT"
      if docker_permission_sudo_failed; then
        add_finding "WARN" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP013" "$(docker_permission_warning_text)"
      fi
      add_finding "INFO" "eap-startup-probe" "$DOCKERFILE_PATH" "-" "EAP011" "Temporary JBoss EAP probe image could not be removed automatically. Output: $(compact_output "$cleanup_output")"
    fi
  fi
}

report_unused_context_files() {
  local full rel
  progress_log "CHECK" "Scanning unreferenced build-context files"
  while IFS= read -r -d '' full; do
    rel="$(rel_to_context "$full")"
    [[ "$rel" == .git/* ]] && continue
    if [[ -z "${REFERENCED_CONTEXT[$rel]:-}" ]] && is_relevant_context_file "$rel"; then
      add_finding "INFO" "build-context" "$full" "-" "CTX010" "Build context file '$rel' is not referenced by COPY/ADD in the Dockerfile."
    fi
  done < <(find "$CONTEXT_DIR" -path '*/.git' -prune -o -type f -print0 -o -type l -print0)
}

check_item_for_code() {
  case "$1" in
    DF*) printf 'Dockerfile syntax and multi-stage build' ;;
    CTX*) printf 'Build context resource relation' ;;
    SYM*) printf 'Symbolic link creation phase' ;;
    EP*) printf 'Entrypoint resolution' ;;
    SH*) printf 'Called shell script relation' ;;
    VAR*) printf 'Shell and Dockerfile variable usage' ;;
    SEC*) printf 'Dockerfile BuildKit build secrets' ;;
    KSH*) printf 'ksh setup consistency' ;;
    RTP*) printf 'Docker runtime executable probe' ;;
    EAP*) printf 'JBoss EAP startup probe' ;;
    UBI*) printf 'UBI 9.6 runtime consistency' ;;
    CLI*) printf 'WildFly jboss-cli syntax' ;;
    JNDI*) printf 'WildFly JNDI configuration' ;;
    SUMMARY) printf 'Check category summary' ;;
    *) printf 'Static check' ;;
  esac
}

result_label_for_severity() {
  case "$1" in
    ERROR) printf '要修正' ;;
    WARN) printf '要確認/改善推奨' ;;
    INFO) printf '情報' ;;
    OK) printf 'OK' ;;
    *) printf '%s' "$1" ;;
  esac
}

suggestion_for_code() {
  local code="$1"
  case "$code" in
    DF001|DF003) printf 'FROM命令を追加し、利用するベースイメージを明示してください。' ;;
    DF002) printf 'マルチステージ名を一意にしてください。COPY --fromで参照しやすい名前に整理するのが安全です。' ;;
    DF004|DF006) printf 'COPY --fromの参照先を既存のステージ番号またはASで定義したステージ名に修正してください。' ;;
    DF005) printf '外部イメージからのCOPYであることを意図しているか確認し、タグを固定してください。' ;;
    DF007) printf 'BuildKitの--link利用が対象環境で有効か確認してください。' ;;
    DF008) printf 'COPY/ADDは少なくとも1つのソースと1つの宛先を指定してください。' ;;
    CTX001) printf '変数を含むCOPY/ADD元は静的解析が難しいため、ARG/ENVの既定値や実ビルド時の値を明記してください。' ;;
    CTX002) printf 'Dockerビルドコンテキスト外のファイルは直接参照できません。必要な資材をコンテキスト内へ配置してください。' ;;
    CTX003) printf '.dockerignoreから除外されているため、COPY/ADD対象にする場合は除外ルールを見直してください。' ;;
    CTX004) printf '破損したシンボリックリンクの参照先を修正するか、実体ファイルを配置してください。' ;;
    CTX005) printf 'コンテキスト外を指すシンボリックリンクはビルド環境差分の原因になります。実体をコンテキスト内に置くことを推奨します。' ;;
    CTX006) printf 'ホスト側コンテキストで提供されるリンクです。Docker build時に期待どおり解決されるか確認してください。' ;;
    CTX007|CTX008) printf 'COPY/ADD元パス、ファイル名、大文字小文字、配置ディレクトリを修正してください。' ;;
    CTX009) printf 'ADDによるリモート取得は再現性が落ちます。可能なら事前取得してコンテキストに含めてください。' ;;
    CTX010) printf '未使用資材であれば削除し、必要な資材ならDockerfileのCOPY/ADDまたは参照経路を追加してください。' ;;
    SYM001) printf 'ビルド時に固定で必要なリンクならDockerfileで妥当です。起動時の状態に依存するならentrypoint側へ移してください。' ;;
    SYM002) printf 'runtimeで作るリンクは冪等性、既存リンク、権限、実行ユーザーを確認してください。固定リンクならDockerfile側で作る方が安定します。' ;;
    EP001|EP002) printf 'ENTRYPOINT/CMDのパスとCOPY先を一致させ、実行権限とshebangも確認してください。' ;;
    EP003|EP004) printf 'DockerfileのENTRYPOINT/CMDを明示するか、--entrypointで解析対象を指定してください。' ;;
    SH001) printf 'basenameによる推定解決です。実際のコンテナ内パスとCOPY先が一致しているか確認してください。' ;;
    SH002|SH003) printf '呼び出し先シェルをビルドコンテキスト内に配置し、COPY先と実行パスを合わせてください。' ;;
    VAR001|VAR003|VAR005) printf '変数定義の構文を修正し、名前と値を明示してください。' ;;
    VAR002) printf 'ENVはkey=value形式へ揃えるとDockerfileの可読性と解析精度が上がります。' ;;
    VAR004|VAR010) printf '空値が意図した初期値か確認し、必要なら既定値を設定してください。' ;;
    VAR006) printf 'ARGに既定値を設定するか、ビルド時に必須で渡すことをREADMEやCIに明記してください。' ;;
    VAR007|VAR011) printf '外部から必須で受け取る変数です。環境変数、secret、起動引数、CI設定のいずれで渡すか明記してください。' ;;
    VAR008|VAR012|VAR013) printf '利用前に初期化するか、${VAR:-default}のような既定値、または${VAR:?message}の必須チェックを追加してください。' ;;
    VAR009|VAR014|VAR015) printf '不要なら削除し、子プロセス向けに必要なら用途をコメントや命名で明確にしてください。' ;;
    SEC001|SEC005) printf 'BuildKit secret mount option syntax is invalid. Fix RUN --mount=type=secret options before building.' ;;
    SEC002|SEC003|SEC004|SEC006|SEC007|SEC008|SEC009|SEC010|SEC014) printf 'Review RUN --mount=type=secret syntax. Use explicit id=, absolute target= or valid env=, octal mode, numeric uid/gid, and pass source values outside the Dockerfile with docker build --secret.' ;;
    SEC011|SEC013) printf 'Build secret usage was detected. Ensure CI/build command passes matching --secret id=... and the secret is not copied into image layers.' ;;
    SEC012) printf 'Consider required=true for mandatory build secrets so builds fail instead of silently proceeding without credentials.' ;;
    KSH001) printf 'ksh setup was detected in the final stage. Use --runtime-probe when you need proof that ksh actually executes in the built image.' ;;
    KSH002|KSH003) printf 'Install ksh in the final Dockerfile stage, or confirm it is provided by the base image with --runtime-probe.' ;;
    KSH004) printf 'Move ksh package installation from entrypoint/runtime shell into the Dockerfile build phase.' ;;
    RTP001) printf 'Install Docker CLI and ensure the Docker daemon is running before using --runtime-probe.' ;;
    RTP002) printf 'Fix the Docker build failure first. If the Dockerfile needs secrets or build args, pass them with repeated --runtime-probe-build-option arguments.' ;;
    RTP003|RTP005) printf 'Runtime executable probe succeeded. Keep this as evidence that the built image can start the requested runtime command.' ;;
    RTP004) printf 'Install ksh in the final image, verify PATH and /bin/sh availability, then rerun --runtime-probe.' ;;
    RTP006) printf 'Install a Java runtime/JDK in the final image, verify PATH/JAVA_HOME, then rerun --runtime-probe.' ;;
    RTP007) printf 'Remove the temporary probe image manually with docker image rm if it is no longer needed.' ;;
    RTP008) printf 'Docker permission error could not be solved by sudo -n. Add the user to the docker group, configure passwordless sudo for docker, or run the checker with appropriate privileges.' ;;
    EAP001) printf 'Install Docker CLI and ensure the Docker daemon is running before using --eap-startup-probe.' ;;
    EAP002) printf 'Fix the Docker build failure first. If the Dockerfile needs secrets or build args, pass them with repeated --eap-startup-build-option arguments.' ;;
    EAP003) printf 'Fix container startup options, required environment variables, volumes, ports, or entrypoint permissions, then rerun --eap-startup-probe.' ;;
    EAP004) printf 'JBoss EAP startup and WAR deployment success logs were found. Keep the listed WAR names and log lines as startup evidence.' ;;
    EAP005) printf 'Confirm the WAR is copied to the EAP deployments directory, deployment scanner is enabled, and the expected WFLYSRV0010 deployment success log appears.' ;;
    EAP006) printf 'Confirm server boot completes and the WFLYSRV0025 startup success log appears before timeout; increase --eap-startup-timeout if startup is slow.' ;;
    EAP007) printf 'Review the failure lines in the startup log and fix deployment, datasource, module, or configuration errors before accepting the image.' ;;
    EAP008) printf 'Increase --eap-startup-timeout only after confirming the server is still progressing; otherwise fix startup blockers shown in the log tail.' ;;
    EAP009) printf 'Inspect the container log tail and exit code. The server process likely terminated before successful boot/deployment.' ;;
    EAP010) printf 'Detected WAR file names are informational; verify they match the application artifacts intended for this image.' ;;
    EAP011) printf 'Remove the temporary probe image or container manually with docker rm/docker image rm if it is no longer needed.' ;;
    EAP012) printf 'Verify the runtime image really contains JBoss EAP 8.1; the startup log did not clearly prove that version.' ;;
    EAP013) printf 'Docker permission error could not be solved by sudo -n. Add the user to the docker group, configure passwordless sudo for docker, or run the checker with appropriate privileges.' ;;
    EAP014) printf 'Select a runnable EAP probe target: use --eap-startup-target build, --eap-startup-from-base when the final FROM resolves to an external image, or --eap-startup-run-image IMAGE for a prebuilt image.' ;;
    EAP015) printf 'The probe is intentionally running an existing/base image and skipping docker build. Use --eap-startup-command if the image has no default CMD that starts JBoss EAP.' ;;
    UBI001|UBI002) printf 'RHEL/UBI 9.6前提ならベースイメージタグを9.6に固定してください。' ;;
    UBI003|UBI004) printf 'UBI minimalではmicrodnf利用とキャッシュ削除を確認してください。パッケージ導入はDockerfileビルド時に寄せるのが基本です。' ;;
    UBI005|UBI012) printf 'subscription-managerに依存しない構成へ見直してください。UBIコンテナはホスト購読状態へ依存させない方が移植性があります。' ;;
    UBI006|UBI011) printf 'systemctl/serviceは通常コンテナ内で期待どおり動きません。プロセスを直接起動するentrypointへ変更してください。' ;;
    UBI007|UBI008) printf '可能なら非rootユーザーを作成し、USERで実行ユーザーを固定してください。必要な権限はビルド時にchown/chmodします。' ;;
    UBI009) printf 'UBI minimalでbash shebangを使う場合はDockerfileでbashを導入するか、/bin/sh互換に修正してください。' ;;
    UBI010) printf 'entrypoint実行時のパッケージ導入は再現性と起動時間を悪化させます。DockerfileのRUNへ移動してください。' ;;
    UBI013) printf 'UBI minimalでuseradd/groupaddを使う場合はshadow-utils導入を確認するか、ビルド時にユーザー作成してください。' ;;
    CLI001) printf '推定解決されたCLIファイルです。jboss-cli.sh --fileのパスとCOPY先の対応を確認してください。' ;;
    CLI002) printf 'CLIファイルをビルドコンテキストに配置し、DockerfileでCOPYしたコンテナ内パスを--fileに指定してください。' ;;
    CLI003|CLI004) printf 'jboss-cliの括弧、引用符、複合値の閉じ忘れを修正してください。' ;;
    CLI005) printf 'WildFly jboss-cliで有効なコマンドか確認し、必要ならbatch/run-batchや/subsystem=...形式へ整理してください。' ;;
    JNDI001) printf 'WildFly/JBossのJNDI名は通常java:/またはjava:jboss/から始めます。アプリ側参照名と合わせて修正してください。' ;;
    JNDI002) printf 'JNDI値に変数を使う場合は既定値や必須チェックを追加し、空値で起動しないようにしてください。' ;;
    JNDI003) printf '重複JNDI名は衝突の原因になります。意図した上書きか、別名にすべきか確認してください。' ;;
    JNDI004|JNDI005|JNDI006|JNDI007|JNDI008) printf 'JNDI/naming/datasource追加に必要な属性を補完し、WildFlyの対象バージョンのCLI仕様に合わせてください。' ;;
    SUMMARY) printf '該当カテゴリの詳細行を確認してください。OKの場合はこのカテゴリで検出された問題はありません。' ;;
    *) printf '対象行の実装意図と実行環境を確認し、必要に応じてDockerfileまたは関連スクリプトを修正してください。' ;;
  esac
}

csv_escape() {
  local s="$1"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

write_csv_row() {
  local field first=1
  for field in "$@"; do
    if (( first )); then
      first=0
    else
      printf ',' >> "$REPORT_FILE"
    fi
    csv_escape "$field" >> "$REPORT_FILE"
  done
  printf '\n' >> "$REPORT_FILE"
}

write_csv_row_to_file() {
  local output="$1"
  shift
  local field first=1
  for field in "$@"; do
    if (( first )); then
      first=0
    else
      printf ',' >> "$output"
    fi
    csv_escape "$field" >> "$output"
  done
  printf '\n' >> "$output"
}

count_codes_by_sev() {
  local sev="$1"
  shift
  local prefix count=0 i code wanted
  for ((i=0; i<${#F_SEV[@]}; i++)); do
    [[ "${F_SEV[$i]}" == "$sev" ]] || continue
    code="${F_CODE[$i]}"
    for wanted in "$@"; do
      if [[ "$code" == "$wanted"* ]]; then
        count=$((count + 1))
        break
      fi
    done
  done
  printf '%s' "$count"
}

write_summary_csv_row() {
  local -n serial_ref="$1"
  local category="$2"
  shift 2
  local errors warns infos severity result msg
  errors=$(count_codes_by_sev "ERROR" "$@")
  warns=$(count_codes_by_sev "WARN" "$@")
  infos=$(count_codes_by_sev "INFO" "$@")
  if (( errors > 0 )); then
    severity="ERROR"
    result="要修正"
  elif (( warns > 0 )); then
    severity="WARN"
    result="要確認/改善推奨"
  elif (( infos > 0 )); then
    severity="INFO"
    result="情報"
  else
    severity="OK"
    result="OK"
  fi
  msg="$category: ERROR=$errors WARN=$warns INFO=$infos"
  write_csv_row "$serial_ref" "$result" "$severity" "SUMMARY" "$category" "summary" "-" "-" "$msg" "$(suggestion_for_code SUMMARY)"
  serial_ref=$((serial_ref + 1))
}

write_report_file() {
  (( REPORT_ENABLED )) || return 0
  local dir serial=1 i file line sev code result item msg suggestion
  dir="$(dirname -- "$REPORT_FILE")"
  mkdir -p -- "$dir"
  progress_log "OUTPUT" "Writing Excel CSV report: $REPORT_FILE"
  printf '\xEF\xBB\xBF' > "$REPORT_FILE"
  write_csv_row "No" "Result" "Severity" "CheckCode" "CheckItem" "Phase" "File" "Line" "Message" "Suggestion"

  write_summary_csv_row serial "Dockerfile構文/マルチステージ" "DF"
  write_summary_csv_row serial "ビルドコンテキスト資材関連" "CTX"
  write_summary_csv_row serial "シンボリックリンク作成フェーズ" "SYM"
  write_summary_csv_row serial "ENTRYPOINT/CMD解決" "EP"
  write_summary_csv_row serial "呼び出しシェル関連" "SH"
  write_summary_csv_row serial "変数利用/初期化" "VAR"
  write_summary_csv_row serial "Dockerfile BuildKit build secrets" "SEC"
  write_summary_csv_row serial "ksh setup consistency" "KSH"
  write_summary_csv_row serial "Docker runtime executable probe" "RTP"
  write_summary_csv_row serial "JBoss EAP startup probe" "EAP"
  write_summary_csv_row serial "WildFly jboss-cli構文" "CLI"
  write_summary_csv_row serial "WildFly JNDI設定" "JNDI"
  write_summary_csv_row serial "UBI 9.6 runtime整合性" "UBI"

  for ((i=0; i<${#F_SEV[@]}; i++)); do
    sev="${F_SEV[$i]}"
    code="${F_CODE[$i]}"
    result="$(result_label_for_severity "$sev")"
    item="$(check_item_for_code "$code")"
    file="$(display_path "${F_FILE[$i]}")"
    line="${F_LINE[$i]}"
    msg="${F_MSG[$i]}"
    suggestion="$(suggestion_for_code "$code")"
    write_csv_row "$serial" "$result" "$sev" "$code" "$item" "${F_PHASE[$i]}" "$file" "$line" "$msg" "$suggestion"
    serial=$((serial + 1))
  done
}

mermaid_escape() {
  local s="$1"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

write_mermaid_file() {
  (( MERMAID_ENABLED )) || return 0
  local dir i label id from to from_id to_id edge_label node_count=1
  declare -A node_ids=()
  declare -A node_labels=()

  dir="$(dirname -- "$MERMAID_FILE")"
  mkdir -p -- "$dir"
  progress_log "OUTPUT" "Writing Mermaid relationship diagram: $MERMAID_FILE"

  for ((i=0; i<${#REL_FROM[@]}; i++)); do
    for label in "${REL_FROM[$i]}" "${REL_TO[$i]}"; do
      if [[ -z "${node_ids[$label]:-}" ]]; then
        id="N$node_count"
        node_ids["$label"]="$id"
        node_labels["$id"]="$label"
        node_count=$((node_count + 1))
      fi
    done
  done

  {
    printf 'flowchart LR\n'
    printf '  classDef dockerfile fill:#d9e8ff,stroke:#3465a4,color:#111827;\n'
    printf '  classDef shell fill:#e8f7df,stroke:#4f8a10,color:#111827;\n'
    printf '  classDef cli fill:#fff4d6,stroke:#b7791f,color:#111827;\n'
    printf '  classDef resource fill:#f3f4f6,stroke:#6b7280,color:#111827;\n'
    if (( ${#REL_FROM[@]} == 0 )); then
      printf '  N1["Dockerfile"]\n'
      printf '  N2["No build-context file relation was detected"]\n'
      printf '  N1 --> N2\n'
    else
      for ((i=1; i<node_count; i++)); do
        id="N$i"
        label="${node_labels[$id]}"
        printf '  %s["%s"]\n' "$id" "$(mermaid_escape "$label")"
      done
      for ((i=0; i<${#REL_FROM[@]}; i++)); do
        from="${REL_FROM[$i]}"
        to="${REL_TO[$i]}"
        from_id="${node_ids[$from]}"
        to_id="${node_ids[$to]}"
        edge_label="${REL_LABEL[$i]}"
        printf '  %s -- "%s" --> %s\n' "$from_id" "$(mermaid_escape "$edge_label")" "$to_id"
      done
    fi
    for ((i=1; i<node_count; i++)); do
      id="N$i"
      label="${node_labels[$id]}"
      case "$(lower "$label")" in
        dockerfile) printf '  class %s dockerfile\n' "$id" ;;
        *.sh|*.bash|*.ksh) printf '  class %s shell\n' "$id" ;;
        *.cli) printf '  class %s cli\n' "$id" ;;
        *) printf '  class %s resource\n' "$id" ;;
      esac
    done
  } > "$MERMAID_FILE"
}

ascii_clean() {
  local s="$1"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}

write_ascii_art_file() {
  (( ASCII_ART_ENABLED )) || return 0
  local dir i from to label source_file source_line phase total seen connector detail_prefix
  declare -A from_seen=()
  declare -a from_order=()

  dir="$(dirname -- "$ASCII_ART_FILE")"
  mkdir -p -- "$dir"
  progress_log "OUTPUT" "Writing ASCII relationship diagram: $ASCII_ART_FILE"

  for ((i=0; i<${#REL_FROM[@]}; i++)); do
    from="${REL_FROM[$i]}"
    if [[ -z "${from_seen[$from]:-}" ]]; then
      from_seen["$from"]=1
      from_order+=("$from")
    fi
  done

  {
    printf 'Docker Context Relationship Diagram (ASCII)\n'
    printf 'Context    : %s\n' "$(ascii_clean "$CONTEXT_DIR")"
    printf 'Dockerfile : %s\n' "$(ascii_clean "$DOCKERFILE_PATH")"
    printf 'Legend     : source --[reason]--> target\n'
    printf '\n'

    if (( ${#REL_FROM[@]} == 0 )); then
      printf 'Dockerfile\n'
      printf '`-- No build-context file relation was detected\n'
      return 0
    fi

    for from in "${from_order[@]}"; do
      total=0
      for ((i=0; i<${#REL_FROM[@]}; i++)); do
        [[ "${REL_FROM[$i]}" == "$from" ]] || continue
        total=$((total + 1))
      done

      printf '%s\n' "$(ascii_clean "$from")"
      seen=0
      for ((i=0; i<${#REL_FROM[@]}; i++)); do
        [[ "${REL_FROM[$i]}" == "$from" ]] || continue
        seen=$((seen + 1))
        to="$(ascii_clean "${REL_TO[$i]}")"
        label="$(ascii_clean "${REL_LABEL[$i]}")"
        phase="$(ascii_clean "${REL_PHASE[$i]}")"
        source_file="$(ascii_clean "$(display_path "${REL_FILE[$i]}")")"
        source_line="$(ascii_clean "${REL_LINE[$i]}")"
        if (( seen == total )); then
          connector='`--'
          detail_prefix='    '
        else
          connector='|--'
          detail_prefix='|   '
        fi
        printf '%s [%s] --> %s\n' "$connector" "$label" "$to"
        printf '%sphase: %s, location: %s:%s\n' "$detail_prefix" "$phase" "$source_file" "$source_line"
      done
      printf '\n'
    done
  } > "$ASCII_ART_FILE"
}

write_variable_report_file() {
  (( VAR_REPORT_ENABLED )) || return 0
  local dir i file value note category action
  dir="$(dirname -- "$VAR_REPORT_FILE")"
  mkdir -p -- "$dir"
  progress_log "OUTPUT" "Writing Excel variable inventory CSV: $VAR_REPORT_FILE"
  printf '\xEF\xBB\xBF' > "$VAR_REPORT_FILE"
  write_csv_row_to_file "$VAR_REPORT_FILE" \
    "No" "VariableName" "Category" "Action" "Phase" "File" "Line" "ConfiguredValue" "Note"

  if (( ${#VAR_NAME[@]} == 0 )); then
    write_csv_row_to_file "$VAR_REPORT_FILE" \
      "1" "-" "No variables detected" "-" "-" "-" "-" "-" "Dockerfile/shell variable references were not detected."
    return 0
  fi

  for ((i=0; i<${#VAR_NAME[@]}; i++)); do
    file="$(display_path "${VAR_FILE[$i]}")"
    value="${VAR_VALUE[$i]}"
    [[ -z "$value" ]] && value="(empty/not configured in this occurrence)"
    category="${VAR_CATEGORY[$i]}"
    action="${VAR_ACTION[$i]}"
    note="${VAR_NOTE[$i]}"
    write_csv_row_to_file "$VAR_REPORT_FILE" \
      "$((i + 1))" "${VAR_NAME[$i]}" "$category" "$action" "${VAR_PHASE[$i]}" "$file" "${VAR_LINE[$i]}" "$value" "$note"
  done
}

write_software_report_file() {
  (( SOFTWARE_REPORT_ENABLED )) || return 0
  local dir i file version note
  dir="$(dirname -- "$SOFTWARE_REPORT_FILE")"
  mkdir -p -- "$dir"
  progress_log "OUTPUT" "Writing Excel software inventory CSV: $SOFTWARE_REPORT_FILE"
  printf '\xEF\xBB\xBF' > "$SOFTWARE_REPORT_FILE"
  write_csv_row_to_file "$SOFTWARE_REPORT_FILE" \
    "No" "SoftwareName" "Type" "Version" "SourceOrInstallMethod" "Phase" "File" "Line" "Evidence" "Note"

  if (( ${#SW_NAME[@]} == 0 )); then
    write_csv_row_to_file "$SOFTWARE_REPORT_FILE" \
      "1" "-" "No software detected" "-" "-" "-" "-" "-" "-" "No base image, install command, Java, application server, or database driver information was detected."
    return 0
  fi

  for ((i=0; i<${#SW_NAME[@]}; i++)); do
    file="$(display_path "${SW_FILE[$i]}")"
    version="${SW_VERSION[$i]}"
    [[ -z "$version" ]] && version="(unknown)"
    note="${SW_NOTE[$i]}"
    write_csv_row_to_file "$SOFTWARE_REPORT_FILE" \
      "$((i + 1))" "${SW_NAME[$i]}" "${SW_TYPE[$i]}" "$version" "${SW_SOURCE[$i]}" "${SW_PHASE[$i]}" "$file" "${SW_LINE[$i]}" "${SW_EVIDENCE[$i]}" "$note"
  done
}

write_config_report_file() {
  (( CONFIG_REPORT_ENABLED )) || return 0
  local dir i file
  dir="$(dirname -- "$CONFIG_REPORT_FILE")"
  mkdir -p -- "$dir"
  progress_log "OUTPUT" "Writing Excel Java/JBoss setting audit CSV: $CONFIG_REPORT_FILE"
  printf '\xEF\xBB\xBF' > "$CONFIG_REPORT_FILE"
  write_csv_row_to_file "$CONFIG_REPORT_FILE" \
    "No" "Domain" "Component" "SettingItem" "Description" "ConfiguredValue" "RecommendedSetting" "DistanceFromRecommendation" "Assessment" "Phase" "File" "Line" "Evidence"

  if (( ${#CFG_SETTING[@]} == 0 )); then
    write_csv_row_to_file "$CONFIG_REPORT_FILE" \
      "1" "-" "-" "No Java/JBoss settings detected" "-" "-" "-" "-" "INFO" "-" "-" "-" "No Java parameters or WildFly/JBoss CLI subsystem settings were detected."
    return 0
  fi

  for ((i=0; i<${#CFG_SETTING[@]}; i++)); do
    file="$(display_path "${CFG_FILE[$i]}")"
    write_csv_row_to_file "$CONFIG_REPORT_FILE" \
      "$((i + 1))" "${CFG_DOMAIN[$i]}" "${CFG_COMPONENT[$i]}" "${CFG_SETTING[$i]}" "${CFG_DESCRIPTION[$i]}" "${CFG_VALUE[$i]}" "${CFG_RECOMMENDED[$i]}" "${CFG_DISTANCE[$i]}" "${CFG_SEVERITY[$i]}" "${CFG_PHASE[$i]}" "$file" "${CFG_LINE[$i]}" "${CFG_EVIDENCE[$i]}"
  done
}

write_ecs_env_report_file() {
  (( ECS_ENV_REPORT_ENABLED )) || return 0
  local dir i file current_value default_value
  dir="$(dirname -- "$ECS_ENV_REPORT_FILE")"
  mkdir -p -- "$dir"
  progress_log "OUTPUT" "Writing Excel ECS environment inventory CSV: $ECS_ENV_REPORT_FILE"
  printf '\xEF\xBB\xBF' > "$ECS_ENV_REPORT_FILE"
  write_csv_row_to_file "$ECS_ENV_REPORT_FILE" \
    "No" "EnvironmentName" "Requirement" "Source" "TaskDefinitionField" "File" "Line" "CurrentValue" "DefaultValue" "Reason" "Evidence"

  if (( ${#ECS_ENV_NAME[@]} == 0 )); then
    write_csv_row_to_file "$ECS_ENV_REPORT_FILE" \
      "1" "-" "No ECS environment candidates detected" "-" "-" "-" "-" "-" "-" "No Dockerfile ENV, shell runtime variable, or WildFly/JBoss CLI expression candidate was detected." "-"
    return 0
  fi

  for ((i=0; i<${#ECS_ENV_NAME[@]}; i++)); do
    file="$(display_path "${ECS_ENV_FILE[$i]}")"
    current_value="${ECS_ENV_CURRENT_VALUE[$i]}"
    default_value="${ECS_ENV_DEFAULT_VALUE[$i]}"
    [[ -z "$current_value" ]] && current_value="(not configured in source)"
    [[ -z "$default_value" ]] && default_value="(none detected)"
    write_csv_row_to_file "$ECS_ENV_REPORT_FILE" \
      "$((i + 1))" "${ECS_ENV_NAME[$i]}" "${ECS_ENV_REQUIREMENT[$i]}" "${ECS_ENV_SOURCE[$i]}" "${ECS_ENV_TASKDEF_FIELD[$i]}" "$file" "${ECS_ENV_LINE[$i]}" "$current_value" "$default_value" "${ECS_ENV_REASON[$i]}" "${ECS_ENV_EVIDENCE[$i]}"
  done
}

container_check_probe_name() {
  case "$1" in
    runtime-probe) printf 'runtime executable probe' ;;
    eap-startup-probe) printf 'JBoss EAP startup probe' ;;
    *) printf '%s' "$1" ;;
  esac
}

container_check_target_mode() {
  case "$1" in
    runtime-probe) printf 'build' ;;
    eap-startup-probe) printf '%s' "${EAP_STARTUP_EFFECTIVE_MODE:-$EAP_STARTUP_TARGET}" ;;
    *) printf '-' ;;
  esac
}

container_check_target_image() {
  case "$1" in
    runtime-probe) printf '%s' "${RUNTIME_PROBE_EFFECTIVE_IMAGE:-${RUNTIME_PROBE_IMAGE:-auto}}" ;;
    eap-startup-probe) printf '%s' "${EAP_STARTUP_EFFECTIVE_IMAGE:-${EAP_STARTUP_RUN_IMAGE:-${EAP_STARTUP_IMAGE:-auto}}}" ;;
    *) printf '-' ;;
  esac
}

container_check_container_name() {
  case "$1" in
    eap-startup-probe) printf '%s' "${EAP_STARTUP_EFFECTIVE_CONTAINER:-${EAP_STARTUP_CONTAINER:-auto}}" ;;
    *) printf '-' ;;
  esac
}

write_container_check_report_file() {
  (( CONTAINER_CHECK_REPORT_ENABLED )) || return 0
  local dir i file line sev code result suggestion phase serial=1 found=0
  dir="$(dirname -- "$CONTAINER_CHECK_REPORT_FILE")"
  mkdir -p -- "$dir"
  progress_log "OUTPUT" "Writing Excel container runtime check CSV: $CONTAINER_CHECK_REPORT_FILE"
  printf '\xEF\xBB\xBF' > "$CONTAINER_CHECK_REPORT_FILE"
  write_csv_row_to_file "$CONTAINER_CHECK_REPORT_FILE" \
    "No" "Probe" "TargetMode" "TargetImage" "ContainerName" "Result" "Severity" "CheckCode" "File" "Line" "Message" "Suggestion"

  for ((i=0; i<${#F_SEV[@]}; i++)); do
    phase="${F_PHASE[$i]}"
    case "$phase" in
      runtime-probe|eap-startup-probe) ;;
      *) continue ;;
    esac
    found=1
    sev="${F_SEV[$i]}"
    code="${F_CODE[$i]}"
    result="$(result_label_for_severity "$sev")"
    file="$(display_path "${F_FILE[$i]}")"
    line="${F_LINE[$i]}"
    suggestion="$(suggestion_for_code "$code")"
    write_csv_row_to_file "$CONTAINER_CHECK_REPORT_FILE" \
      "$serial" "$(container_check_probe_name "$phase")" "$(container_check_target_mode "$phase")" "$(container_check_target_image "$phase")" "$(container_check_container_name "$phase")" "$result" "$sev" "$code" "$file" "$line" "${F_MSG[$i]}" "$suggestion"
    serial=$((serial + 1))
  done

  if (( ! found )); then
    write_csv_row_to_file "$CONTAINER_CHECK_REPORT_FILE" \
      "1" "-" "-" "-" "-" "情報" "INFO" "NO_CONTAINER_CHECKS" "-" "-" "No Docker runtime or JBoss EAP startup probe results were recorded. Enable --runtime-probe or --eap-startup-probe to populate this report." "必要な場合は --runtime-probe または --eap-startup-probe を指定してください。"
  fi
}

print_header() {
  local stages stage_label
  stages=$((FINAL_STAGE + 1))
  stage_label="$FINAL_STAGE"
  [[ -n "${STAGE_NAME[$FINAL_STAGE]:-}" ]] && stage_label+=" (${STAGE_NAME[$FINAL_STAGE]})"

  printf 'Docker Context Checker %s\n' "$VERSION"
  printf 'Context    : %s\n' "$CONTEXT_DIR"
  printf 'Dockerfile : %s\n' "$DOCKERFILE_PATH"
  printf 'Stages     : %s\n' "$stages"
  if (( FINAL_STAGE >= 0 )); then
    printf 'Final stage: %s, base=%s, workdir=%s\n' "$stage_label" "$FINAL_BASE" "$FINAL_WORKDIR"
    if (( FINAL_IS_UBI96 )); then
      printf 'UBI check  : final image is detected as Universal Base Image 9.6%s\n' "$([[ $FINAL_IS_UBI_MINIMAL -eq 1 ]] && printf ' minimal' || true)"
    elif (( FINAL_IS_UBI9 )); then
      printf 'UBI check  : final image is UBI 9 family but not detected as 9.6\n'
    else
      printf 'UBI check  : final image is not detected as UBI 9.6\n'
    fi
  fi
  printf 'Summary    : ERROR=%s WARN=%s INFO=%s\n' "${F_COUNT[ERROR]:-0}" "${F_COUNT[WARN]:-0}" "${F_COUNT[INFO]:-0}"
  if (( REPORT_ENABLED )); then
    printf 'CSV report : %s\n' "$REPORT_FILE"
  fi
  if (( MERMAID_ENABLED )); then
    printf 'Mermaid    : %s\n' "$MERMAID_FILE"
  fi
  if (( ASCII_ART_ENABLED )); then
    printf 'ASCII art  : %s\n' "$ASCII_ART_FILE"
  fi
  if (( VAR_REPORT_ENABLED )); then
    printf 'Variables  : %s\n' "$VAR_REPORT_FILE"
  fi
  if (( SOFTWARE_REPORT_ENABLED )); then
    printf 'Software   : %s\n' "$SOFTWARE_REPORT_FILE"
  fi
  if (( CONFIG_REPORT_ENABLED )); then
    printf 'Config     : %s\n' "$CONFIG_REPORT_FILE"
  fi
  if (( ECS_ENV_REPORT_ENABLED )); then
    printf 'ECS env    : %s\n' "$ECS_ENV_REPORT_FILE"
  fi
  if (( CONTAINER_CHECK_REPORT_ENABLED )); then
    printf 'Container  : %s\n' "$CONTAINER_CHECK_REPORT_FILE"
  fi
  if (( RUNTIME_PROBE_ENABLED )); then
    printf 'Docker run : runtime probe enabled, image=%s\n' "${RUNTIME_PROBE_IMAGE:-auto}"
  fi
  if (( EAP_STARTUP_PROBE_ENABLED )); then
    printf 'EAP probe  : enabled, target=%s, image=%s, timeout=%ss\n' "$EAP_STARTUP_TARGET" "${EAP_STARTUP_RUN_IMAGE:-${EAP_STARTUP_IMAGE:-auto}}" "$EAP_STARTUP_TIMEOUT"
  fi
  printf '\n'
}

print_findings_for() {
  local sev="$1" i file line phase
  local count=0
  for ((i=0; i<${#F_SEV[@]}; i++)); do
    [[ "${F_SEV[$i]}" == "$sev" ]] || continue
    count=$((count + 1))
    file="$(display_path "${F_FILE[$i]}")"
    line="${F_LINE[$i]}"
    phase="${F_PHASE[$i]}"
    printf '[%s] %-18s %s:%s %s  %s\n' "$sev" "$phase" "$file" "$line" "${F_CODE[$i]}" "${F_MSG[$i]}"
  done
  (( count > 0 ))
}

print_report() {
  print_header
  if (( ${#F_SEV[@]} == 0 )); then
    printf 'No findings.\n'
    return 0
  fi
  print_findings_for "ERROR" || true
  print_findings_for "WARN" || true
  print_findings_for "INFO" || true
}

main() {
  parse_args "$@"
  CONTEXT_DIR="$(abs_path "$CONTEXT_DIR")"
  [[ -d "$CONTEXT_DIR" ]] || die "Context directory does not exist: $CONTEXT_DIR"
  if [[ -z "$DOCKERFILE_PATH" ]]; then
    DOCKERFILE_PATH="$CONTEXT_DIR/Dockerfile"
  elif [[ "$DOCKERFILE_PATH" != /* && ! "$DOCKERFILE_PATH" =~ ^[A-Za-z]: ]]; then
    DOCKERFILE_PATH="$CONTEXT_DIR/$DOCKERFILE_PATH"
  fi
  DOCKERFILE_PATH="$(abs_path "$DOCKERFILE_PATH")"
  [[ -f "$DOCKERFILE_PATH" ]] || die "Dockerfile does not exist: $DOCKERFILE_PATH"
  if (( REPORT_ENABLED )); then
    [[ -z "$REPORT_FILE" ]] && REPORT_FILE="$PWD/docker-context-checker-results.csv"
    REPORT_FILE="$(abs_path "$REPORT_FILE")"
  fi
  if (( MERMAID_ENABLED )); then
    [[ -z "$MERMAID_FILE" ]] && MERMAID_FILE="$PWD/docker-context-relations.mmd"
    MERMAID_FILE="$(abs_path "$MERMAID_FILE")"
  fi
  if (( ASCII_ART_ENABLED )); then
    [[ -z "$ASCII_ART_FILE" ]] && ASCII_ART_FILE="$PWD/docker-context-relations.txt"
    ASCII_ART_FILE="$(abs_path "$ASCII_ART_FILE")"
  fi
  if (( VAR_REPORT_ENABLED )); then
    [[ -z "$VAR_REPORT_FILE" ]] && VAR_REPORT_FILE="$PWD/docker-context-checker-variables.csv"
    VAR_REPORT_FILE="$(abs_path "$VAR_REPORT_FILE")"
  fi
  if (( SOFTWARE_REPORT_ENABLED )); then
    [[ -z "$SOFTWARE_REPORT_FILE" ]] && SOFTWARE_REPORT_FILE="$PWD/docker-context-checker-software.csv"
    SOFTWARE_REPORT_FILE="$(abs_path "$SOFTWARE_REPORT_FILE")"
  fi
  if (( CONFIG_REPORT_ENABLED )); then
    [[ -z "$CONFIG_REPORT_FILE" ]] && CONFIG_REPORT_FILE="$PWD/docker-context-checker-config.csv"
    CONFIG_REPORT_FILE="$(abs_path "$CONFIG_REPORT_FILE")"
  fi
  if (( ECS_ENV_REPORT_ENABLED )); then
    [[ -z "$ECS_ENV_REPORT_FILE" ]] && ECS_ENV_REPORT_FILE="$PWD/docker-context-checker-ecs-env.csv"
    ECS_ENV_REPORT_FILE="$(abs_path "$ECS_ENV_REPORT_FILE")"
  fi
  if (( CONTAINER_CHECK_REPORT_ENABLED )); then
    [[ -z "$CONTAINER_CHECK_REPORT_FILE" ]] && CONTAINER_CHECK_REPORT_FILE="$PWD/docker-context-checker-container-checks.csv"
    CONTAINER_CHECK_REPORT_FILE="$(abs_path "$CONTAINER_CHECK_REPORT_FILE")"
  fi

  progress_log "START" "Context=$CONTEXT_DIR Dockerfile=$DOCKERFILE_PATH"
  progress_log "CHECK" "Loading .dockerignore patterns"
  load_dockerignore
  progress_log "CHECK" "Parsing Dockerfile instructions and multi-stage definitions"
  parse_dockerfile
  if (( FINAL_STAGE >= 0 )); then
    progress_log "CHECK" "Analyzing Dockerfile COPY/ADD/RUN/ARG/ENV/UBI checks"
    analyze_dockerfile
    progress_log "CHECK" "Resolving ENTRYPOINT/CMD shell targets"
    resolve_entrypoint
    scan_all_shells
    scan_all_cli
    report_unused_context_files
    if (( RUNTIME_PROBE_ENABLED )); then
      run_runtime_probe
    fi
    if (( EAP_STARTUP_PROBE_ENABLED )); then
      run_eap_startup_probe
    fi
  fi
  progress_log "DONE" "Checks completed"
  write_report_file
  write_mermaid_file
  write_ascii_art_file
  write_variable_report_file
  write_software_report_file
  write_config_report_file
  write_ecs_env_report_file
  write_container_check_report_file
  print_report

  case "$FAIL_ON" in
    error)
      (( ${F_COUNT[ERROR]:-0} == 0 )) || exit 1
      ;;
    warn)
      (( ${F_COUNT[ERROR]:-0} == 0 && ${F_COUNT[WARN]:-0} == 0 )) || exit 1
      ;;
    never)
      ;;
  esac
}

main "$@"
