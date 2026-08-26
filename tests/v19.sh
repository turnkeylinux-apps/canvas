#!/bin/bash
set -euo pipefail

: "${TKL_TEST_RESULT:?TKL_TEST_RESULT must name the result file}"
: "${TKL_TEST_APP_PASS:?TKL_TEST_APP_PASS must contain the firstboot Canvas password}"

APP_ROOT=/var/www/canvas
RCE_ROOT=/var/www/canvas-rce-api
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

html_input_value() {
    local name=$1
    python3 -c '
from html.parser import HTMLParser
import sys

class InputParser(HTMLParser):
    value = None

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "input" and values.get("name") == sys.argv[1]:
            self.value = values.get("value")

parser = InputParser()
parser.feed(sys.stdin.read())
if parser.value is None:
    raise SystemExit(1)
print(parser.value)
' "$name"
}

cookie_value() {
    local cookie_file=$1
    local name=$2
    python3 -c '
import sys
from urllib.parse import unquote

value = None
with open(sys.argv[1], encoding="utf-8") as cookie_file:
    for line in cookie_file:
        fields = line.rstrip("\n").split("\t")
        if len(fields) == 7 and fields[5] == sys.argv[2]:
            value = fields[6]
if value is None:
    raise SystemExit(1)
print(unquote(value))
' "$cookie_file" "$name"
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
canvas_asset_patch_commit=$(source_value canvas_asset_patch_commit)
canvas_asset_patch_sha256=$(source_value canvas_asset_patch_sha256)
rce_commit=$(source_value rce_commit)
rce_tree=$(source_value rce_tree)
rce_sha256=$(source_value rce_archive_sha256)
rce_runtime_dependency_fix=$(source_value rce_runtime_dependency_fix)
rce_runtime_patch_sha256=$(source_value rce_runtime_patch_sha256)
rce_passenger_sha256=$(source_value rce_passenger_sha256)

[[ $version = 2026-04-22 ]] || fail "unexpected Canvas production version"
[[ $canvas_commit = 44bfdc264d5fe6a942ebdb5f10a0eb63ee04df3a ]] \
    || fail "unexpected Canvas production commit"
[[ $canvas_tree = dd2a9caa6afe683108a493a13c32340e1b3ac5e6 ]] \
    || fail "unexpected Canvas source tree"
[[ $canvas_sha256 = 2ca116f8a130b970c7b945fd547e760bdb8e7b8d0ea4c1c63f07222fd874009c ]] \
    || fail "unexpected Canvas archive digest"
[[ $canvas_asset_patch_commit = 9f8cd4be107659b17a29a28dc553f9453c21da4a ]] \
    || fail "unexpected Canvas asset patch commit"
[[ $canvas_asset_patch_sha256 = 2a46919cd35b598ab0c7e4d2b6eeaf6138253fde7107407d800c83f65d88fc31 ]] \
    || fail "unexpected Canvas asset patch digest"
echo "$canvas_asset_patch_sha256  /usr/local/share/turnkey-canvas/canvas_platform_alerts.patch" \
    | sha256sum --check --status \
    || fail "Canvas asset patch integrity check failed"
grep -Fqx "import {showFlashAlert} from '@canvas/alerts/react/FlashAlert'" \
    "$APP_ROOT/ui/features/discovery_page/react/components/ConfigureModal.tsx" \
    || fail "official Canvas asset fix is not applied"
[[ $rce_commit = e076fe28a09f4e41058da0983b5ef2c809123d9f ]] \
    || fail "unexpected Canvas RCE commit"
[[ $rce_tree = 4a2e99c1efccf0011215bb074065a0859135a132 ]] \
    || fail "unexpected Canvas RCE source tree"
[[ $rce_sha256 = 1b36c2231c09d406053c92fde9d805211e538265e8d01827477a3ce9187c0495 ]] \
    || fail "unexpected Canvas RCE archive digest"
[[ $rce_runtime_dependency_fix = local-patch ]] \
    || fail "unexpected Canvas RCE runtime dependency fix state"
[[ $rce_runtime_patch_sha256 = bcf60f9a304e9311dfea6c843f5bafbaf8ede812668d33523e1cceb818068413 ]] \
    || fail "unexpected Canvas RCE runtime patch digest"
[[ $rce_passenger_sha256 = 6c20617d717b2a4af2ae8903e7785e5efe7a0e124f1a4cd6c12bfb9855a87299 ]] \
    || fail "unexpected Canvas RCE Passenger launcher digest"
echo "$rce_runtime_patch_sha256  /usr/local/share/turnkey-canvas/canvas_rce_runtime_dependency.patch" \
    | sha256sum --check --status \
    || fail "Canvas RCE runtime patch integrity check failed"
echo "$rce_passenger_sha256  /usr/local/share/turnkey-canvas/canvas_rce_passenger.js" \
    | sha256sum --check --status \
    || fail "Canvas RCE Passenger launcher integrity check failed"
echo "$rce_passenger_sha256  $RCE_ROOT/turnkey-passenger.js" \
    | sha256sum --check --status \
    || fail "installed Canvas RCE Passenger launcher integrity check failed"
python3 - "$RCE_ROOT/package.json" "$RCE_ROOT/package-lock.json" <<'PY' \
    || fail "Canvas RCE runtime dependency metadata is not production-safe"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as package_file:
    package = json.load(package_file)
with open(sys.argv[2], encoding="utf-8") as lock_file:
    lock = json.load(lock_file)
root = lock["packages"][""]
dev_null = lock["packages"]["node_modules/dev-null"]
assert package["dependencies"]["dev-null"] == "0.1.1"
assert "dev-null" not in package["devDependencies"]
assert root["dependencies"]["dev-null"] == "0.1.1"
assert "dev-null" not in root["devDependencies"]
assert dev_null.get("dev") is not True
PY

ruby_version=$(ruby -e 'print RUBY_VERSION')
rails_version=$(cd "$APP_ROOT" && RAILS_ENV=production \
    BUNDLE_PATH=vendor/bundle bundle exec rails runner 'print Rails.version')
node_version=$(node --version)
yarn_version=$(yarn --version)
[[ $ruby_version == 3.4.* ]] || fail "Canvas is not running Ruby 3.4"
[[ $rails_version == 8.0.* ]] || fail "Canvas is not running Rails 8.0"
[[ $node_version == v20.* ]] || fail "Canvas is not using Node.js 20"
[[ $yarn_version == 1.22.* ]] || fail "Canvas is not using Yarn Classic 1.22"
[[ $(source_value yarn) = "$yarn_version" ]] \
    || fail "Canvas provenance does not match the installed Yarn version"
[[ $(source_value yarn_source) = official-yarn-apt ]] \
    || fail "Canvas provenance does not identify the official Yarn channel"

systemctl is-active --quiet apache2 || fail "Apache is not active"
systemctl is-active --quiet postgresql || fail "PostgreSQL is not active"
systemctl is-active --quiet redis-server || fail "Redis is not active"
apache2ctl configtest 2>&1 | grep -q 'Syntax OK' || fail "Apache configuration is invalid"
grep -Fq 'PassengerStartupFile turnkey-passenger.js' \
    /etc/apache2/sites-available/canvas.conf \
    || fail "Canvas RCE does not use the verified Passenger launcher"
grep -Fq 'PassengerUser www-data' /etc/apache2/sites-available/canvas.conf \
    || fail "Canvas RCE Passenger user is not explicit"
grep -Fq 'PassengerGroup www-data' /etc/apache2/sites-available/canvas.conf \
    || fail "Canvas RCE Passenger group is not explicit"
redis-cli ping | grep -qx PONG || fail "Redis did not answer PING"
grep -Fq 'exec su -s /bin/bash www-data' "$APP_ROOT/script/canvas_init" \
    || fail "Canvas background job launcher does not use the explicit runtime account"
! grep -Fq 'stat -c %U' "$APP_ROOT/script/canvas_init" \
    || fail "Canvas background job launcher derives its runtime account from file ownership"
pgrep -u www-data -f 'delayed_job|inst_jobs' >/dev/null \
    || fail "Canvas background job workers are not running"

cookie=$(mktemp)
pass_file=$(mktemp)
trap 'rm -f "$cookie" "$pass_file"' EXIT
chmod 0600 "$cookie" "$pass_file"
printf '%s' "$TKL_TEST_APP_PASS" > "$pass_file"
curl_args=(--insecure -fsS --max-time 60 -c "$cookie" -b "$cookie")

login_page=
for _ in $(seq 1 60); do
    if login_page=$(curl "${curl_args[@]}" -L \
            "$BASE_URL/login/canvas" 2>/dev/null); then
        break
    fi
    sleep 5
done
require_contains "$login_page" "Canvas" "Canvas HTTPS login page"
login_csrf_token=$(html_input_value authenticity_token <<<"$login_page") \
    || fail "Canvas login form did not contain an authenticity token"

curl "${curl_args[@]}" -L "$BASE_URL/login/canvas" \
    -H "Referer: $BASE_URL/login/canvas" \
    --data-urlencode "authenticity_token=$login_csrf_token" \
    --data-urlencode "pseudonym_session[unique_id]=$LOGIN_EMAIL" \
    --data-urlencode "pseudonym_session[password]@$pass_file" \
    --data-urlencode 'pseudonym_session[remember_me]=0' \
    -o /dev/null

dashboard=$(curl "${curl_args[@]}" "$BASE_URL/")
require_contains "$dashboard" "Dashboard" "authenticated Canvas dashboard"
csrf_token=$(cookie_value "$cookie" _csrf_token) \
    || fail "authenticated Canvas session did not contain a CSRF token"

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

rce_body=$(curl --insecure -fsS --max-time 30 https://localhost:3000/) \
    || fail "Canvas RCE HTTPS service did not return HTTP 200"
require_contains "$rce_body" "Hello, from RCE Service" "Canvas RCE HTTPS service"
rce_readiness=$(curl --insecure -fsS --max-time 30 \
    https://localhost:3000/readiness) \
    || fail "Canvas RCE readiness service did not return HTTP 200"
require_contains "$rce_readiness" '"name":"Rich Content Service"' \
    "Canvas RCE readiness service"

check_output=$(turnkey-canvas-update --check)
candidate=$(awk -F= '$1 == "candidate" {print $2}' <<<"$check_output")
candidate_tree=$(awk -F= '$1 == "candidate_tree" {print $2}' <<<"$check_output")
candidate_rce=$(awk -F= '$1 == "candidate_rce" {print $2}' <<<"$check_output")
asset_fix=$(awk -F= '$1 == "asset_fix" {print $2}' <<<"$check_output")
rce_dependency_fix=$(awk -F= '$1 == "rce_dependency_fix" {print $2}' \
    <<<"$check_output")
[[ $candidate =~ ^[0-9a-f]{40}$ ]] || fail "updater returned an invalid Canvas commit"
[[ $candidate_tree =~ ^[0-9a-f]{40}$ ]] || fail "updater returned an invalid Canvas tree"
[[ $candidate_rce =~ ^[0-9a-f]{40}$ ]] || fail "updater returned an invalid RCE commit"
require_contains "$check_output" "channel=official-canvas-prod" "Canvas updater"
require_contains "$check_output" \
    "asset_patch_commit=$canvas_asset_patch_commit" "Canvas updater"
[[ $asset_fix = required || $asset_fix = upstream ]] \
    || fail "Canvas updater returned an invalid asset fix state"
[[ $rce_dependency_fix = required || $rce_dependency_fix = upstream ]] \
    || fail "Canvas updater returned an invalid RCE dependency fix state"
require_contains "$check_output" \
    "rce_runtime_patch_sha256=$rce_runtime_patch_sha256" "Canvas updater"
require_contains "$check_output" \
    "rce_passenger_sha256=$rce_passenger_sha256" "Canvas updater"

apply_plan=$(turnkey-canvas-update --apply --dry-run)
require_contains "$apply_plan" "mode=apply-dry-run" "Canvas updater plan"
require_contains "$apply_plan" "target=$candidate" "Canvas updater plan"
require_contains "$apply_plan" "target_tree=$candidate_tree" "Canvas updater plan"
require_contains "$apply_plan" "rce_target=$candidate_rce" "Canvas updater plan"
require_contains "$apply_plan" "asset_fix=$asset_fix" "Canvas updater plan"
require_contains "$apply_plan" "rce_dependency_fix=$rce_dependency_fix" \
    "Canvas updater plan"
require_contains "$apply_plan" \
    "asset_patch_commit=$canvas_asset_patch_commit" "Canvas updater plan"
require_contains "$apply_plan" \
    "rce_runtime_patch_sha256=$rce_runtime_patch_sha256" "Canvas updater plan"
require_contains "$apply_plan" \
    "rce_passenger_sha256=$rce_passenger_sha256" "Canvas updater plan"
require_contains "$apply_plan" \
    "verified=official-branch-commits-trees-and-compatibility-fixes" \
    "Canvas updater plan"

# Prove the real update lifecycle in this disposable exact runtime. The helper
# installs a verified compatible prior Canvas/RCE source and database, applies
# the updater to the already resolved current heads, then repeats the normal
# login, course, service, asset and RCE checks while verifying backups and
# preserved configuration/data.
source /run/tkl-v19-tests/tests/v19-updater-apply.sh
exercise_real_updater_apply \
    "$candidate" "$candidate_tree" "$candidate_rce" \
    "$(awk -F= '$1 == "candidate_rce_tree" {print $2}' <<<"$check_output")"

apt-get update -qq \
    -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/yarn.list \
    -o Dir::Etc::sourceparts=- \
    -o APT::Get::List-Cleanup=0
yarn_policy=$(apt-cache policy yarn)
require_contains "$yarn_policy" "https://dl.yarnpkg.com/debian" \
    "official Yarn update channel"
yarn_candidate=$(sed -n 's/^  Candidate: //p' <<<"$yarn_policy" | head -n 1)
[[ -n $yarn_candidate && $yarn_candidate != '(none)' ]] \
    || fail "official Yarn update channel did not return a candidate"

echo "PASS: Canvas login, course create/read, PostgreSQL, Redis, jobs, assets, RCE and real updater apply"
echo "version=$version rails=$rails_version yarn=$yarn_version canvas_commit=$canvas_commit rce_commit=$rce_commit"
cat > "$TKL_TEST_RESULT" <<EOF
package_source=official Canvas prod at $canvas_commit and official RCE at $rce_commit
installed_version=Canvas production release $version on Rails $rails_version, Ruby $ruby_version and Yarn $yarn_version
runtime_checks=HTTPS firstboot login, course create/read, PostgreSQL, Redis, background jobs, compiled assets, RCE, real prior-to-current updater apply and official Yarn metadata passed
updater_command=turnkey-canvas-update --check; turnkey-canvas-update --apply --dry-run; real --apply from Canvas $PREVIOUS_CANVAS_COMMIT and RCE $PREVIOUS_RCE_COMMIT; apt-get update for official Yarn source
updater_result=applied official Canvas commit $candidate with tree $candidate_tree and RCE commit $candidate_rce; backup $update_apply_backup_id; apply log SHA256 $update_apply_log_sha256; Yarn package $yarn_candidate
updater_channel=official Canvas prod, Canvas RCE master and signed official Yarn APT channels
integrity_evidence=Canvas archive SHA256 $canvas_sha256 and RCE archive SHA256 $rce_sha256 bound to exact commits and trees; compatible prior Canvas archive SHA256 $PREVIOUS_CANVAS_SHA256 and RCE archive SHA256 $PREVIOUS_RCE_SHA256 verified; RCE runtime patch SHA256 $rce_runtime_patch_sha256 and Passenger launcher SHA256 $rce_passenger_sha256 verified; Yarn packages verified by signed APT metadata
EOF
