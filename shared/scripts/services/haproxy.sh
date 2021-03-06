#!/bin/bash
set -eou pipefail

# shellcheck disable=SC2154
pod_script_env_file="$var_pod_script"

function error {
	"$pod_script_env_file" "util:error" --error="${BASH_SOURCE[0]}: line ${BASH_LINENO[0]}: ${*}"
}

command="${1:-}"

if [ -z "$command" ]; then
	error "No command entered."
fi

shift;

# shellcheck disable=SC2214
while getopts ':-:' OPT; do
	if [ "$OPT" = "-" ]; then   # long option: reformulate OPT and OPTARG
		OPT="${OPTARG%%=*}"       # extract long option name
		OPTARG="${OPTARG#$OPT}"   # extract long option argument (may be empty)
		OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
	fi
	case "$OPT" in
		task_info ) arg_task_info="${OPTARG:-}";;
		toolbox_service ) arg_toolbox_service="${OPTARG:-}";;
		haproxy_service ) arg_haproxy_service="${OPTARG:-}";;

		max_amount ) arg_max_amount="${OPTARG:-}";;

		output_file ) arg_output_file="${OPTARG:-}";;
		manual_file ) arg_manual_file="${OPTARG:-}";;
		allowed_hosts_file ) arg_allowed_hosts_file="${OPTARG:-}";;
		file_exclude_paths ) arg_file_exclude_paths="${OPTARG:-}";;
		log_file_day ) arg_log_file_day="${OPTARG:-}";;
		log_file_last_day ) arg_log_file_last_day="${OPTARG:-}";;
		amount_day ) arg_amount_day="${OPTARG:-}";;
		log_file_last_hour ) arg_log_file_last_hour="${OPTARG:-}";;
		log_file_hour ) arg_log_file_hour="${OPTARG:-}";;
		amount_hour ) arg_amount_hour="${OPTARG:-}";;

		log_file ) arg_log_file="${OPTARG:-}";;
		log_idx_ip ) arg_log_idx_ip="${OPTARG:-}";;
		log_idx_user ) arg_log_idx_user="${OPTARG:-}";;
		log_idx_http_user ) arg_log_idx_http_user="${OPTARG:-}";;
		log_idx_duration ) arg_log_idx_duration="${OPTARG:-}";;
		log_idx_status ) arg_log_idx_status="${OPTARG:-}";;
		log_idx_time ) arg_log_idx_time="${OPTARG:-}";;
		??* ) error "$command: Illegal option --$OPT" ;;  # bad long option
		\? )  exit 2 ;;  # bad short option (error reported via getopts)
	esac
done
shift $((OPTIND-1))

title=''
[ -n "${arg_task_info:-}" ] && title="${arg_task_info:-} > "
title="${title}${command}"

case "$command" in
	"service:haproxy:start")
		>&2 "$pod_script_env_file" up "$arg_haproxy_service"
		;;
	"service:haproxy:reload")
		>&2 "$pod_script_env_file" kill -s HUP "$arg_haproxy_service"
		;;
	"service:haproxy:basic_status")
		"$pod_script_env_file" exec-nontty "$arg_toolbox_service" /bin/bash <<-SHELL || error "$title"
			set -eou pipefail

			echo -e "##############################################################################################################"
			echo -e "HAProxy Sessions"
			echo -e "--------------------------------------------------------------------------------------------------------------"

			curl --silent "http://haproxy:9081/stats;csv" \
				| grep -e pxname -e FRONTEND -e BACKEND \
				| cut -d "," -f 1,2,5-8,34,35 \
				| column -s, -t

			echo -e "##############################################################################################################"
			echo -e "HAProxy - Requests"
			echo -e "--------------------------------------------------------------------------------------------------------------"

			curl --silent "http://haproxy:9081/stats;csv" \
				| grep -e pxname -e FRONTEND -e BACKEND \
				| cut -d "," -f 1,2,11,47,48,78,79 \
				| column -s, -t

			echo -e "##############################################################################################################"
			echo -e "HAProxy - IO & Status"
			echo -e "--------------------------------------------------------------------------------------------------------------"

			curl --silent "http://haproxy:9081/stats;csv" \
				| grep -e pxname -e FRONTEND -e BACKEND \
				| cut -d "," -f 1,2,9,10,41-44 \
				| column -s, -t

			echo -e "##############################################################################################################"
		SHELL
		;;
	"service:haproxy:block_ips")
		default_prefix=">>> "
		log_prefix="${arg_log_prefix:-$default_prefix}"

		reload="$("$pod_script_env_file" exec-nontty "$arg_toolbox_service" /bin/bash 				<<-SHELL || error "$title"
			set -eou pipefail

			function error {
				>&2 echo -e "\$(date '+%F %T') - \${BASH_SOURCE[0]}: line \${BASH_LINENO[0]}: \${*}"
				exit 2
			}

			function invalid_cidr_network() {
				[[ "\$1" =~ ^(([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])(\.)){3}([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]] && echo "0" || echo "1"
			}

			grep_args=( "$log_prefix" )

			function ipstoblock {
				haproxy_file_path="\${1:-}"
				amount="\${2:-10}"
				ips_most_requests=''

				if [ -f "\$haproxy_file_path" ]; then
					ips_most_requests=\$( \
						{ \
							grep \${grep_args[@]} "\$haproxy_file_path" \
							| awk '{print \$2}' \
							| sort \
							| uniq -c \
							| sort -nr \
							| awk -v amount="\$amount" '{if(\$1 > amount) {printf "%s # %s\n", \$2, \$1}}' \
							||:; \
						} \
						| head -n "$arg_max_amount" \
					)
				fi

				if [ -n "\$ips_most_requests" ]; then
					output=''

					while read -r i; do
						ip="\$(echo "\$i" | awk '{print \$1}')"
						invalid_ip="\$(invalid_cidr_network "\$ip")" ||:

						if [ "\${invalid_ip:-1}" = "1" ]; then
							>&2 echo "invalid ip: \$ip";
						else
							# include ip if it isn't already defined
							# it will be considered as defined even if it is commented
							if ! grep -qE "^([#]+[ ]*)?\${ip}([ ].*)?$" "$arg_output_file"; then
								output_aux="\n\$i";

								# do nothing if ip already exists in manual file
								if [ -n "${arg_manual_file:-}" ] && [ -f "${arg_manual_file:-}" ]; then
									if grep -qE "^(\$ip|#[ ]*\$ip|##[ ]*\$ip)" "${arg_manual_file:-}"; then
										output_aux=''
									fi
								fi

								if [ -n "\$output_aux" ]; then
									host="\$(host "\$ip" | awk '{ print \$NF }' | sed 's/.\$//' ||:)"

									if [ -n "\$host" ] && [ -n "${arg_allowed_hosts_file:-}" ]; then
										regex="^[ ]*[^#^ ].*$"
										allowed_hosts="\$(grep -E "\$regex" "${arg_allowed_hosts_file:-}" ||:)"

										if [ -n "\$allowed_hosts" ]; then
											while read -r allowed_host; do
												if [[ \$host == \$allowed_host ]]; then
													ip_host="$(host "\$host" | awk '{ print $NF }' ||:)"

													if [ -n "\$ip_host" ] && [ "\$ip" = "\$ip_host" ]; then
														output_aux="\n## \$i (\$host)";
													fi

													break;
												fi
											done <<< "\$(echo -e "\$allowed_hosts")"
										fi
									fi
								fi

								output="\$output\$output_aux";
							fi
						fi
					done <<< "\$(echo -e "\$ips_most_requests")"

					if [ -n "\$output" ]; then
						output="#\$(TZ=GMT date '+%F %T')\$output"
						echo -e "\n\$output" | tee --append "$arg_output_file" > /dev/null
					fi
				fi
			}

			if [ ! -f "$arg_output_file" ]; then
				mkdir -p "${arg_output_file%/*}" && touch "$arg_output_file"
			fi

			iba1=\$(md5sum "$arg_output_file")

			if [ -n "${arg_log_file_last_day:-}" ] && [ -f "${arg_log_file_last_day:-}" ]; then
				if [ "${arg_amount_day:-}" -le "0" ]; then
					error "$title: amount_day (${arg_amount_day:-}) should be greater than 0"
				fi

				>&2 echo "define ips to block (more than ${arg_amount_day:-} requests in the last day) - ${arg_log_file_last_day:-}"
				ipstoblock "${arg_log_file_last_day:-}" "${arg_amount_day:-}"
			fi

			if [ -n "${arg_log_file_day:-}" ] && [ -f "${arg_log_file_day:-}" ]; then
				if [ "${arg_amount_day:-}" -le "0" ]; then
					error "$title: amount_day (${arg_amount_day:-}) should be greater than 0"
				fi

				>&2 echo "define ips to block (more than ${arg_amount_day:-} requests in a day) - ${arg_log_file_day:-}"
				ipstoblock "${arg_log_file_day:-}" "${arg_amount_day:-}"
			fi

			if [ -n "${arg_log_file_last_hour:-}" ] && [ -f "${arg_log_file_last_hour:-}" ]; then
				if [ "${arg_amount_hour:-}" -le "0" ]; then
					error "$title: amount_hour (${arg_amount_hour:-}) should be greater than 0"
				fi

				>&2 echo "define ips to block (more than ${arg_amount_hour:-} requests in the last hour) - ${arg_log_file_last_hour:-}"
				ipstoblock "${arg_log_file_last_hour:-}" "${arg_amount_hour:-}"
			fi

			if [ -n "${arg_log_file_hour:-}" ] && [ -f "${arg_log_file_hour:-}" ]; then
				if [ "${arg_amount_hour:-}" -le "0" ]; then
					error "$title: amount_hour (${arg_amount_hour:-}) should be greater than 0"
				fi

				>&2 echo "define ips to block (more than ${arg_amount_hour:-} requests in an hour) - ${arg_log_file_hour:-}"
				ipstoblock "${arg_log_file_hour:-}" "${arg_amount_hour:-}"
			fi

			iba2=\$(md5sum "$arg_output_file")

			if [ "\$iba1" != "\$iba2" ]; then
				echo "true"
			else
				echo "false"
			fi
		SHELL
		)"

		if [ "$reload" = "true" ]; then
			>&2 "$pod_script_env_file" "service:haproxy:reload" --haproxy_service="$arg_haproxy_service"
		fi
		;;
	"service:haproxy:log:summary:total")
		default_prefix=">>> "
		log_prefix="${arg_log_prefix:-$default_prefix}"

		"$pod_script_env_file" exec-nontty "$arg_toolbox_service" /bin/bash <<-SHELL || error "$title"
			set -eou pipefail

			function error {
				>&2 echo -e "\$(date '+%F %T') - \${BASH_SOURCE[0]}: line \${BASH_LINENO[0]}: \${*}"
				exit 2
			}

			echo -e "##############################################################################################################"
			echo -e "##############################################################################################################"
			echo -e "Haproxy Logs"
			echo -e "--------------------------------------------------------------------------------------------------------------"
			echo -e "Path: $arg_log_file"
			echo -e "Limit: $arg_max_amount"
			echo -e "--------------------------------------------------------------------------------------------------------------"

			grep_args=( "$log_prefix" )

			request_count="\$(wc -l < "$arg_log_file")"
			echo -e "Requests: \$request_count"

			if [ -n "${arg_log_idx_user:-}" ]; then
				total_users="\$( \
					{ \
						grep \${grep_args[@]} "$arg_log_file" \
						| awk -v idx="${arg_log_idx_user:-}" '{print \$idx}' | sort | uniq -c | wc -l \
						||:; \
					} | head -n 1)" || error "$title: total_users"
				echo -e "Users: \$total_users"
			fi

			if [ -n "${arg_log_idx_http_user:-}" ]; then
				total_http_users="\$( \
					{ \
						grep \${grep_args[@]} "$arg_log_file" \
						| awk -v idx="${arg_log_idx_http_user:-}" '{print \$idx}' | sort | uniq -c | wc -l \
						||:; \
					} | head -n 1)" \
					|| error "$title: total_http_users"
				echo -e "HTTP Users: \$total_http_users"
			fi

			if [ -n "${arg_log_idx_duration:-}" ]; then
				total_duration="\$( \
					{ \
						grep \${grep_args[@]} "$arg_log_file" \
						| awk -v idx="${arg_log_idx_duration:-}" '{s+=\$idx} END {print s}' \
						||:; \
					} | head -n 1)" \
					|| error "$title: total_duration"
				echo -e "Duration: \$total_duration"
			fi

			if [ -n "${arg_log_idx_ip:-}" ]; then
				echo -e "##############################################################################################################"
				echo -e "Ips with Most Requests"
				echo -e "--------------------------------------------------------------------------------------------------------------"

				ips_most_requests="\$( \
					{ \
						grep \${grep_args[@]} "$arg_log_file" \
						| awk -v idx="${arg_log_idx_ip:-}" '{print \$idx}' \
						| sort | uniq -c | sort -nr ||:; \
					} | head -n "$arg_max_amount")" \
					|| error "$title: ips_most_requests"
				echo -e "\$ips_most_requests"
			fi

			if [ -n "${arg_log_idx_ip:-}" ] && [ -n "${arg_log_idx_duration:-}" ]; then
				echo -e "======================================================="
				echo -e "IPs with Most Request Duration (s)"
				echo -e "--------------------------------------------------------------------------------------------------------------"

				ips_most_request_duration="\$( \
					{ \
						grep \${grep_args[@]} "$arg_log_file" \
						| awk \
							-v idx_ip="${arg_log_idx_ip:-}" \
							-v idx_duration="${arg_log_idx_duration:-}" \
							'{s[\$idx_ip]+=\$idx_duration} END \
							{ for (key in s) { printf "%10.1f %s\n", s[key], key } }' \
						| sort -nr ||:;  \
					} | head -n "$arg_max_amount")" \
					|| error "$title: ips_most_request_duration"
				echo -e "\$ips_most_request_duration"
			fi

			if [ -n "${arg_log_idx_user:-}" ]; then
				echo -e "======================================================="
				echo -e "Users with Most Requests"
				echo -e "--------------------------------------------------------------------------------------------------------------"

				users_most_requests="\$( \
					{ \
						grep \${grep_args[@]} "$arg_log_file" \
						| awk -v idx="${arg_log_idx_user:-}" '{print \$idx}' \
						| sort | uniq -c | sort -nr ||:; \
					} | head -n "$arg_max_amount")" \
					|| error "$title: users_most_requests"
				echo -e "\$users_most_requests"
			fi

			if [ -n "${arg_log_idx_user:-}" ] && [ -n "${arg_log_idx_duration:-}" ]; then
				echo -e "======================================================="
				echo -e "Users with Biggest Sum of Requests Duration (s)"
				echo -e "--------------------------------------------------------------------------------------------------------------"

				users_most_request_duration="\$( \
					{ \
						grep \${grep_args[@]} "$arg_log_file" \
						| awk -v idx_user="${arg_log_idx_user:-}" -v idx_duration="${arg_log_idx_duration:-}" \
						'{s[\$idx_user]+=\$idx_duration} END { for (key in s) { printf "%10.1f %s\n", s[key], key } }' \
						| sort -nr ||:; \
					} | head -n "$arg_max_amount")" \
          			|| error "$title: users_most_request_duration"
				echo -e "\$users_most_request_duration"
			fi

			if [ -n "${arg_log_idx_status:-}" ]; then
				echo -e "======================================================="
				echo -e "Status with Most Requests"
				echo -e "--------------------------------------------------------------------------------------------------------------"

				status_most_requests="\$( \
					{ \
						grep \${grep_args[@]} "$arg_log_file" \
						| awk -v idx="${arg_log_idx_status:-}" '{print \$idx}' \
						| sort | uniq -c | sort -nr ||:; \
					} | head -n "$arg_max_amount")" \
          			|| error "$title: status_most_requests"
				echo -e "\$status_most_requests"
			fi

			if [ -n "${arg_log_idx_duration:-}" ]; then
				echo -e "======================================================="
				echo -e "Requests with Longest Duration (s)"
				echo -e "--------------------------------------------------------------------------------------------------------------"

				grep_other_args=()

				if [ -n "${arg_file_exclude_paths:-}" ] && [ -f "${arg_file_exclude_paths:-}" ]; then
					regex="^[ ]*[^#^ ].*$"
					grep_lines="\$(grep -E "\$regex" "${arg_file_exclude_paths:-}" ||:)"

					if [ -n "\$grep_lines" ]; then
						while read -r grep_line; do
							if [ "\${#grep_other_args[@]}" -eq 0 ]; then
								grep_other_args=( "-v" )
							fi

							grep_other_args+=( "-e" "\$grep_line" )
						done <<< "\$(echo -e "\$grep_lines")"
					fi
				fi

				if [ "\${#grep_other_args[@]}" -eq 0 ]; then
					grep_other_args=( "." )
				fi

				longest_request_durations="\$( \
					{ \
						grep \${grep_args[@]} "$arg_log_file" \
						| grep \${grep_other_args[@]} \
						| awk \
							-v idx_ip="${arg_log_idx_ip:-}" \
							-v idx_user="${arg_log_idx_user:-}" \
							-v idx_duration="${arg_log_idx_duration:-}" \
							-v idx_time="${arg_log_idx_time:-}" \
							-v idx_status="${arg_log_idx_status:-}" \
							'{ printf "%10.1f %s %s %s %s\n", \
								\$idx_duration, \
								substr(\$idx_time, index(\$idx_time, ":") + 1), \
								\$idx_status, \
								\$idx_user, \
								\$idx_ip }' \
						| sort -nr ||:; \
					} | head -n "$arg_max_amount")" \
					|| error "$title: longest_request_durations"
				echo -e "\$longest_request_durations"
			fi
		SHELL
		;;
	"service:haproxy:log:duration")
		default_prefix=">>> "
		log_prefix="${arg_log_prefix:-$default_prefix}"

		"$pod_script_env_file" exec-nontty "$arg_toolbox_service" /bin/bash <<-SHELL || error "$title"
			set -eou pipefail

			function error {
				>&2 echo -e "\$(date '+%F %T') - \${BASH_SOURCE[0]}: line \${BASH_LINENO[0]}: \${*}"
				exit 2
			}

			if [ -n "${arg_log_idx_duration:-}" ]; then
				grep_args=( "$log_prefix" )

				grep_other_args=()

				if [ -n "${arg_file_exclude_paths:-}" ] && [ -f "${arg_file_exclude_paths:-}" ]; then
					regex="^[ ]*[^#^ ].*$"
					grep_lines="\$(grep -E "\$regex" "${arg_file_exclude_paths:-}" ||:)"

					if [ -n "\$grep_lines" ]; then
						while read -r grep_line; do
							if [ "\${#grep_other_args[@]}" -eq 0 ]; then
								grep_other_args=( "-v" )
							fi

							grep_other_args+=( "-e" "\$grep_line" )
						done <<< "\$(echo -e "\$grep_lines")"
					fi
				fi

				if [ "\${#grep_other_args[@]}" -eq 0 ]; then
					grep_other_args=( "." )
				fi

				longest_request_durations="\$( \
					{
						grep \${grep_args[@]} "$arg_log_file" \
						| grep \${grep_other_args[@]} \
						| awk \
							-v idx_duration="${arg_log_idx_duration:-}" \
							'{ printf "%10.1f %s\n", \$idx_duration, \$0 }' \
							| sort -nr ||:; \
					} | head -n "$arg_max_amount")" \
					|| error "$title: longest_request_durations"
				echo -e "\$longest_request_durations"
			fi
		SHELL
		;;
	"service:haproxy:log:connections")
		echo -e "##############################################################################################################"
		echo -e "HAProxy connections summary: Unsupported action"
		echo -e "##############################################################################################################"
		;;
	*)
		error "$title: invalid command"
		;;
esac