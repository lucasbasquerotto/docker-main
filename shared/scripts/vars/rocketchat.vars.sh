#!/bin/bash
set -eou pipefail

tmp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export var_load_name='rocketchat'
export var_load_db_service='mongo'
export var_db_restore_type='mongo:dir'

tmp_authentication_database="${var_load__db_main__authentication_database:-admin}"
export var_load__db_main__authentication_database="$tmp_authentication_database"

function tmp_error {
	echo "${BASH_SOURCE[0]}: line ${BASH_LINENO[0]}: ${*}" >&2
	exit 2
}

tmp_errors=()

# specific vars...
export var_custom__use_custom_ssl="${var_load_use__custom_ssl:-}"

tmp_error_count=${#tmp_errors[@]}

if [[ $tmp_error_count -gt 0 ]]; then
	for (( i=1; i<tmp_error_count+1; i++ )); do
		echo "$i/${tmp_error_count}: ${tmp_errors[$i-1]}" >&2
	done
fi

tmp_error_count_aux="$tmp_error_count"
tmp_error_count=0

# shellcheck disable=SC1090
. "$tmp_dir/shared.vars.sh"

tmp_shared_error_count="${tmp_error_count:-0}"

tmp_final_error_count=$((tmp_error_count_aux + tmp_shared_error_count))

if [[ $tmp_final_error_count -gt 0 ]]; then
	tmp_error "$tmp_final_error_count error(s) when loading the variables"
fi