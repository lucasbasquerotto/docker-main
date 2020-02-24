#!/bin/bash
# shellcheck disable=SC1090,SC2154,SC2153
set -eou pipefail

pod_vars_dir="$POD_VARS_DIR"
pod_layer_dir="$POD_LAYER_DIR"
pod_full_dir="$POD_FULL_DIR"
pod_script_env_file="$POD_SCRIPT_ENV_FILE"

. "${pod_vars_dir}/vars.sh"

pod_env_shared_file="$pod_layer_dir/$var_scripts_dir/shared.sh"

pod_layer_base_dir="$(dirname "$pod_layer_dir")"
base_dir="$(dirname "$pod_layer_base_dir")"

CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

if [ -z "$base_dir" ] || [ "$base_dir" = "/" ]; then
  msg="This project must be in a directory structure of type"
  msg="$msg [base_dir]/[pod_layer_base_dir]/[this_repo] with"
  msg="$msg base_dir different than '' or '/' instead of $pod_layer_dir"
  echo -e "${RED}${msg}${NC}"
  exit 1
fi

ctl_layer_dir="$base_dir/ctl"
app_layer_dir="$base_dir/apps/$var_wordpress_dev_repo_dir"

command="${1:-}"

if [ -z "$command" ]; then
	echo -e "${RED}No command entered (env).${NC}"
	exit 1
fi

shift;

start="$(date '+%F %X')"

case "$command" in
  "prepare"|"setup"|"deploy"|"stop"|"rm"|"clear")
    echo -e "${CYAN}$(date '+%F %X') - env (local) - $command - start${NC}"
    ;;
esac

case "$command" in
  "prepare")
    "$ctl_layer_dir/run" dev-cmd bash "/root/w/r/$var_env_local_repo/run" "${@}"

    sudo chmod +x "$app_layer_dir/"
    cp "$pod_full_dir/main/wordpress/.env" "$app_layer_dir/.env"
    chmod +r "$app_layer_dir/.env"
    chmod 777 "$app_layer_dir/web/app/uploads/"
    ;;
	"setup")
    "$pod_env_shared_file" rm wordpress composer 
    "$pod_env_shared_file" stop mysql
    "$pod_env_shared_file" up mysql composer
    "$pod_env_shared_file" exec composer composer install --verbose
		"$pod_env_shared_file" "$command"
		;;
  "deploy")
    cd "$pod_full_dir"
    "$pod_env_shared_file" rm wordpress composer 
    "$pod_env_shared_file" stop mysql
    "$pod_env_shared_file" up mysql composer
    "$pod_env_shared_file" exec composer composer clear-cache
    "$pod_env_shared_file" exec composer composer update --verbose
		"$pod_env_shared_file" "$command" "$@"
    ;;
  "stop"|"rm")
		"$pod_env_shared_file" "$command" "$@"
    "$ctl_layer_dir/run" "$command"
    ;;
  "clear")
    "$pod_script_env_file" rm
    sudo rm -rf "${base_dir}/data/${var_env}/${var_ctx}/${var_pod_name}/"
    sudo docker volume rm -f "${var_env}-${var_ctx}-${var_pod_name}_mysql"
    ;;
	*)
		"$pod_env_shared_file" "$command" "$@"
    ;;
esac

end="$(date '+%F %X')"

case "$command" in
  "prepare"|"setup"|"deploy"|"stop"|"rm"|"clear")
    echo -e "${CYAN}$(date '+%F %X') - env (local) - $command - end${NC}"
    echo -e "${CYAN}env (local) - $command - $start - $end${NC}"
    ;;
esac