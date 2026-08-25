#!/bin/bash
set -euo pipefail

: "${TKL_TEST_RESULT:?TKL_TEST_RESULT must name the result file}"
: "${TKL_TEST_APP_PASS:?TKL_TEST_APP_PASS must contain the firstboot Canvas password}"

APP_ROOT=/var/www/canvas
SOURCE_FILE=/usr/local/share/turnkey-canvas/source
BASE_URL=https://localhost
LOGIN_EMAIL=admin@example.invalid

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_contains() {
    local text=$1
    local expected=$2
    local context=$3
    [[ $text == *"$expected"* ]] || fail "$context did not contain: $expected"
}

source_value() {
    local key=$1
    sed -n "s/^${key}=//p" "$SOURCE_FILE" | head -n 1
}

[[ -r $SOURCE_FILE ]] || fail "Canvas source provenance is missing"
[[ -x /usr/local/bin/turnkey-canvas-update ]] || fail "Canvas updater is not executable"

version=$(source_value version)
canvas_commit=$(source_value canvas_commit)
canvas_tree=$(source_value canvas_tree)
canvas_sha256=$(source_value canvas_archive_sha256)
rce_commit=$(source_value rce_commit)
rce_tree=$(source_value rce_tree)
rce_sha256=$(source_value rce_archive_sha256)

[[ $version = 2026-04-22 ]] || fail "unexpected Canvas production version"
[[ $canvas_commit = 44bfdc264d5fe6a942ebdb5f10a0eb63ee04df3a ]] \
    || fail "unexpected Canvas production commit"
[[ $canvas_tree = dd2a9caa6afe683108a493a13c32340e1b3ac5e6 ]] \
    || fail "unexpected Canvas source tree"
[[ $canvas_sha256 = 2ca116f8a130b970c7b945fd547e760bdb8e7b8d0ea4c1c63f07222fd874009c ]] \
    || fail "unexpected Canvas archive digest"
[[ $rce_commit = e076fe28a09f4e41058da0983b5ef2c809123d9f ]] \
    || fail "unexpected Canvas RCE commit"
[[ $rce_tree = 4a2e99c1efccf0011215bb074065a0859135a132 ]] \
    || fail "unexpected Canvas RCE source tree"
[[ $rce_sha256 = 1b36c2231c09d406053c92fde9d805211e538265e8d01827477a3ce9187c0495 ]] \
    || fail "unexpected Canvas RCE archive digest"

ruby_version=$(ruby -e 'print RUBY_VERSION')
rails_version=$(cd "$APP_ROOT" && RAILS_ENV=production \
    BUNDLE_PATH=vendor/bundle bundle exec rails runner 'print Rails.version')
node_version=$(node --version)
[[ $ruby_version == 3.4.* ]] || fail "Canvas is not running Ruby 3.4"
[[ $rails_version == 8.0.* ]] || fail "Canvas is not running Rails 8.0"
[[ $node_version == v20.* ]] || fail "Canvas is not using Node.js 20"

systemctl is-active --quiet apache2 || fail "Apache is not active"
systemctl is-active --quiet postgresql || fail "PostgreSQL is not active"
systemctl is-active --quiet redis-server || fail "Redis is not active"
apache2ctl configtest 2>&1 | grep -q 'Syntax OK' || fail "Apache configuration is invalid"
redis-cli ping | grep -qx PONG || fail "Redis did not answer PING"
pgrep -u www-data -f 'delayed_job|inst_jobs' >/dev/null \
    || fail "Canvas background job workers are not running"

login_page=
for _ in $(seq 1 60); do
    if login_page=$(curl --insecure -fsSL --max-time 30 \
            "$BASE_URL/login/canvas" 2>/dev/null); then
        break
    fi
    sleep 5
done
require_contains "$login_page" "Canvas" "Canvas HTTPS login page"

cookie=$(mktemp)
pass_file=$(mktemp)
trap 'rm -f "$cookie" "$pass_file"' EXIT
chmod 0600 "$cookie" "$pass_file"
printf '%s' "$TKL_TEST_APP_PASS" > "$pass_file"
curl_args=(--insecure -fsS --max-time 60 -c "$cookie" -b "$cookie")

curl "${curl_args[@]}" -L "$BASE_URL/login/canvas" \
    -H "Referer: $BASE_URL/login/canvas" \
    --data-urlencode "pseudonym_session[unique_id]=$LOGIN_EMAIL" \
    --data-urlencode "pseudonym_session[password]@$pass_file" \
    --data-urlencode 'pseudonym_session[remember_me]=0' \
    -o /dev/null

dashboard=$(curl "${curl_args[@]}" "$BASE_URL/")
require_contains "$dashboard" "Dashboard" "authenticated Canvas dashboard"
csrf_tag=$(grep -o '<meta[^>]*name="csrf-token"[^>]*>' <<<"$dashboard" | head -n 1)
csrf_token=$(sed -n 's/.*content="\([^"]*\)".*/\1/p' <<<"$csrf_tag")
[[ -n $csrf_token ]] || fail "authenticated Canvas page did not contain a CSRF token"

course_name='TurnKey Canvas acceptance course'
course_code='TKL-V19'
course_json=$(curl "${curl_args[@]}" \
    -H "X-CSRF-Token: $csrf_token" \
    -H 'Accept: application/json' \
    "$BASE_URL/api/v1/accounts/1/courses" \
    --data-urlencode "course[name]=$course_name" \
    --data-urlencode "course[course_code]=$course_code" \
    --data-urlencode 'course[is_public]=true' \
    --data-urlencode 'offer=true')
course_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' \
    <<<"$course_json")
[[ $course_id =~ ^[0-9]+$ ]] || fail "Canvas API did not create a course"
require_contains "$course_json" "$course_name" "Canvas course create response"

course_read=$(curl "${curl_args[@]}" -H 'Accept: application/json' \
    "$BASE_URL/api/v1/courses/$course_id")
require_contains "$course_read" "$course_name" "Canvas course read response"
course_page=$(curl "${curl_args[@]}" "$BASE_URL/courses/$course_id")
require_contains "$course_page" "$course_name" "Canvas course page"

db_course=$(su postgres -c \
    "psql --tuples-only --no-align canvas_production --command=\"SELECT name || '|' || course_code FROM courses WHERE id=$course_id\"")
[[ $db_course = "$course_name|$course_code" ]] \
    || fail "PostgreSQL did not retain the created Canvas course"

asset_path=$(sed -n 's/.*href="\([^"]*\/dist\/[^"]*\.css[^"]*\)".*/\1/p' \
    <<<"$login_page" | head -n 1)
[[ -n $asset_path ]] || fail "Canvas login page did not reference a compiled CSS asset"
asset_size=$(curl --insecure -fsSL --max-time 60 \
    "$BASE_URL$asset_path" | wc -c)
[[ $asset_size -gt 100 ]] || fail "Canvas compiled CSS asset was empty"

rce_status=$(curl --insecure -sS --max-time 30 -o /dev/null \
    -w '%{http_code}' https://localhost:3000/)
[[ $rce_status = 200 || $rce_status = 404 ]] \
    || fail "Canvas RCE HTTPS service returned $rce_status"

check_output=$(turnkey-canvas-update --check)
candidate=$(awk -F= '$1 == "candidate" {print $2}' <<<"$check_output")
candidate_tree=$(awk -F= '$1 == "candidate_tree" {print $2}' <<<"$check_output")
candidate_rce=$(awk -F= '$1 == "candidate_rce" {print $2}' <<<"$check_output")
[[ $candidate =~ ^[0-9a-f]{40}$ ]] || fail "updater returned an invalid Canvas commit"
[[ $candidate_tree =~ ^[0-9a-f]{40}$ ]] || fail "updater returned an invalid Canvas tree"
[[ $candidate_rce =~ ^[0-9a-f]{40}$ ]] || fail "updater returned an invalid RCE commit"
require_contains "$check_output" "channel=official-canvas-prod" "Canvas updater"

apply_plan=$(turnkey-canvas-update --apply --dry-run)
require_contains "$apply_plan" "mode=apply-dry-run" "Canvas updater plan"
require_contains "$apply_plan" "target=$candidate" "Canvas updater plan"
require_contains "$apply_plan" "target_tree=$candidate_tree" "Canvas updater plan"
require_contains "$apply_plan" "rce_target=$candidate_rce" "Canvas updater plan"
require_contains "$apply_plan" "verified=official-branch-commits-and-trees" "Canvas updater plan"

echo "PASS: Canvas login, course create/read, PostgreSQL, Redis, jobs, assets, RCE and updater"
echo "version=$version rails=$rails_version canvas_commit=$canvas_commit rce_commit=$rce_commit"
cat > "$TKL_TEST_RESULT" <<EOF
package_source=official Canvas prod at $canvas_commit and official RCE at $rce_commit
installed_version=Canvas production release $version on Rails $rails_version and Ruby $ruby_version
runtime_checks=HTTPS firstboot login, course create/read, PostgreSQL, Redis, background jobs, compiled assets and RCE passed
updater_command=turnkey-canvas-update --check; turnkey-canvas-update --apply --dry-run
updater_result=eligible official Canvas commit $candidate with tree $candidate_tree and RCE commit $candidate_rce
updater_channel=official Canvas prod and Canvas RCE master branches
integrity_evidence=Canvas archive SHA256 $canvas_sha256 and RCE archive SHA256 $rce_sha256 bound to exact commits and trees
EOF
