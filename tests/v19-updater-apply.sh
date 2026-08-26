#!/bin/bash

# This file is sourced by tests/v19.sh after the normal Canvas flow passes.
# It replaces the disposable runtime with a verified compatible prior source
# and database, then exercises the real supervised update back to the current
# production and RCE heads.

PREVIOUS_CANVAS_VERSION=2026-04-08
PREVIOUS_CANVAS_COMMIT=727a00ece21c7c3bcf1193f3244560f8074acd43
PREVIOUS_CANVAS_TREE=5188b4896a558cbb65e7afadba2ca0ffc71b34e1
PREVIOUS_CANVAS_SHA256=bdb18c5a0a9f462bec2c5f806125e7b5b56ee215c5f033650471fe4a25cca7c0
PREVIOUS_RCE_VERSION=v1.27.6
PREVIOUS_RCE_COMMIT=d702ab3bd201cc3bad19abd32cec22e7fd9e1701
PREVIOUS_RCE_TREE=4fa8916e68484c551868f6db43ea898eeb10d87a
PREVIOUS_RCE_SHA256=8626ff40dd472142a38f9189eaf03839fcf28c75018c7d23cd16d3ebe39c0a66

config_manifest_sha256() {
    (
        cd "$APP_ROOT/config"
        find . -maxdepth 1 -type f -name '*.yml' -print \
            | LC_ALL=C sort \
            | xargs sha256sum \
            | sha256sum \
            | awk '{print $1}'
    )
}

remote_commit_tree() {
    local api=$1
    local commit=$2
    curl -fsSL "$api/git/commits/$commit" | python3 -c '
import json
import re
import sys

tree = json.load(sys.stdin).get("tree", {}).get("sha", "")
if not re.fullmatch(r"[0-9a-f]{40}", tree):
    raise SystemExit(1)
print(tree, end="")
'
}

exercise_real_updater_apply() {
    local expected_canvas=$1
    local expected_canvas_tree=$2
    local expected_rce=$3
    local expected_rce_tree=$4
    local stage canvas_archive rce_archive old_canvas old_rce prior_bundle
    local branch_head tag_head config_hash rce_env_hash
    local prior_check apply_log apply_output backup_root db_backup files_backup
    local update_post_check
    local login_page login_csrf_token dashboard csrf_token
    local post_course_name post_course_code post_course_json post_course_id
    local post_course_read post_course_page db_courses asset_path asset_size
    local rce_body rce_readiness prior_rails_version

    [[ $expected_canvas = 44bfdc264d5fe6a942ebdb5f10a0eb63ee04df3a ]] \
        || fail "updater apply target is not the accepted Canvas production commit"
    [[ $expected_canvas_tree = dd2a9caa6afe683108a493a13c32340e1b3ac5e6 ]] \
        || fail "updater apply target is not the accepted Canvas source tree"
    [[ $expected_rce = e076fe28a09f4e41058da0983b5ef2c809123d9f ]] \
        || fail "updater apply target is not the accepted RCE commit"
    [[ $expected_rce_tree = 4a2e99c1efccf0011215bb074065a0859135a132 ]] \
        || fail "updater apply target is not the accepted RCE source tree"

    branch_head=$(git ls-remote https://github.com/instructure/canvas-lms.git \
        refs/heads/stable/2026-04-08 | awk 'NR == 1 {print $1}')
    [[ $branch_head = "$PREVIOUS_CANVAS_COMMIT" ]] \
        || fail "compatible Canvas fixture branch moved"
    tag_head=$(git ls-remote https://github.com/instructure/canvas-rce-api.git \
        'refs/tags/v1.27.6^{}' | awk 'NR == 1 {print $1}')
    [[ $tag_head = "$PREVIOUS_RCE_COMMIT" ]] \
        || fail "compatible RCE fixture tag moved"
    [[ $(remote_commit_tree \
        https://api.github.com/repos/instructure/canvas-lms \
        "$PREVIOUS_CANVAS_COMMIT") = "$PREVIOUS_CANVAS_TREE" ]] \
        || fail "compatible Canvas fixture tree changed"
    [[ $(remote_commit_tree \
        https://api.github.com/repos/instructure/canvas-rce-api \
        "$PREVIOUS_RCE_COMMIT") = "$PREVIOUS_RCE_TREE" ]] \
        || fail "compatible RCE fixture tree changed"

    stage=$(mktemp -d /var/tmp/turnkey-canvas-update-test.XXXXXX)
    canvas_archive=$stage/canvas.tar.gz
    rce_archive=$stage/rce.tar.gz
    curl -fsSL \
        "https://github.com/instructure/canvas-lms/archive/$PREVIOUS_CANVAS_COMMIT.tar.gz" \
        -o "$canvas_archive"
    curl -fsSL \
        "https://github.com/instructure/canvas-rce-api/archive/$PREVIOUS_RCE_COMMIT.tar.gz" \
        -o "$rce_archive"
    echo "$PREVIOUS_CANVAS_SHA256  $canvas_archive" \
        | sha256sum --check --status \
        || fail "compatible Canvas fixture archive failed integrity verification"
    echo "$PREVIOUS_RCE_SHA256  $rce_archive" \
        | sha256sum --check --status \
        || fail "compatible RCE fixture archive failed integrity verification"
    tar -xzf "$canvas_archive" -C "$stage"
    tar -xzf "$rce_archive" -C "$stage"
    old_canvas=$stage/canvas-lms-$PREVIOUS_CANVAS_COMMIT
    old_rce=$stage/canvas-rce-api-$PREVIOUS_RCE_COMMIT

    if grep -Fqx \
            "import {showFlashAlert} from '@instructure/platform-alerts'" \
            "$old_canvas/ui/features/discovery_page/react/components/ConfigureModal.tsx"; then
        git -C "$old_canvas" apply \
            /usr/local/share/turnkey-canvas/canvas_platform_alerts.patch
    elif ! grep -Fqx \
            "import {showFlashAlert} from '@canvas/alerts/react/FlashAlert'" \
            "$old_canvas/ui/features/discovery_page/react/components/ConfigureModal.tsx"; then
        fail "compatible Canvas fixture has an unexpected asset import"
    fi
    git -C "$old_canvas" apply \
        /usr/local/share/turnkey-canvas/canvas_init.patch
    python3 - "$old_rce/package.json" "$old_rce/package-lock.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as package_file:
    package = json.load(package_file)
with open(sys.argv[2], encoding="utf-8") as lock_file:
    lock = json.load(lock_file)

version = package["devDependencies"].pop("dev-null")
package.setdefault("dependencies", {})["dev-null"] = version
root = lock["packages"][""]
root_version = root["devDependencies"].pop("dev-null")
root.setdefault("dependencies", {})["dev-null"] = root_version
lock["packages"]["node_modules/dev-null"].pop("dev", None)
lock.get("dependencies", {}).get("dev-null", {}).pop("dev", None)

for path, value in ((sys.argv[1], package), (sys.argv[2], lock)):
    with open(path, "w", encoding="utf-8") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
PY
    install -m 0644 \
        /usr/local/share/turnkey-canvas/canvas_rce_passenger.js \
        "$old_rce/turnkey-passenger.js"

    service canvas_init stop
    service apache2 stop
    rsync -a --delete \
        --exclude=/.bundle \
        --exclude=/config/GEM_HOME \
        --exclude='/config/*.yml' \
        --exclude=/log \
        --exclude=/tmp \
        --exclude=/vendor/bundle \
        "$old_canvas/" "$APP_ROOT/"
    rsync -a --delete \
        --exclude=/.env \
        --exclude=/tmp \
        "$old_rce/" "$RCE_ROOT/"

    cd "$APP_ROOT"
    prior_bundle=$stage/prior-bundle
    bundle config set --local path "$prior_bundle"
    BUNDLE_PATH=$prior_bundle bundle install
    service postgresql start
    service redis-server start
    su postgres -c 'dropdb --if-exists canvas_production'
    su postgres -c 'dropdb --if-exists canvas_queue'
    su postgres -c 'createdb --owner canvas -EUTF8 canvas_production'
    su postgres -c 'createdb --owner canvas -EUTF8 canvas_queue'
    export RAILS_ENV=production
    export BUNDLE_PATH=$prior_bundle
    export CANVAS_LMS_ADMIN_EMAIL=$LOGIN_EMAIL
    export CANVAS_LMS_ADMIN_PASSWORD=$TKL_TEST_APP_PASS
    export CANVAS_LMS_ACCOUNT_NAME='TurnKey Canvas updater acceptance'
    export CANVAS_LMS_STATS_COLLECTION=opt-out
    bundle exec rake db:initial_setup
    bundle exec rake db:migrate
    bundle exec rake switchman_inst_jobs:install:migrations

    update_prior_course_name='TurnKey Canvas updater preserved course'
    update_prior_course_code='TKL-V19-PRE'
    update_prior_course_id=$(bundle exec rails runner \
        "course = Account.find(1).courses.create!(name: '$update_prior_course_name', course_code: '$update_prior_course_code', workflow_state: 'available'); print course.id" \
        | tail -n 1)
    [[ $update_prior_course_id =~ ^[0-9]+$ ]] \
        || fail "compatible Canvas fixture did not create preserved course data"

    install -m 0440 -o root -g www-data /dev/null \
        "$APP_ROOT/config/turnkey-updater-acceptance.yml"
    printf 'fixture: compatible-prior-release\n' \
        > "$APP_ROOT/config/turnkey-updater-acceptance.yml"
    install -d -m 0750 -o www-data -g www-data "$APP_ROOT/tmp/files"
    printf 'TurnKey Canvas updater preserved file data\n' \
        > "$APP_ROOT/tmp/files/turnkey-updater-acceptance.txt"
    chown www-data:www-data \
        "$APP_ROOT/tmp/files/turnkey-updater-acceptance.txt"
    config_hash=$(config_manifest_sha256)
    rce_env_hash=$(sha256sum "$RCE_ROOT/.env" | awk '{print $1}')
    prior_rails_version=$(bundle exec rails --version | awk '{print $2}')

    # The real updater must see the production bundle location from the prior
    # installation, not the disposable dependency path used to construct its
    # database fixture.
    bundle config set --local path vendor/bundle
    unset BUNDLE_PATH

    cat > "$SOURCE_FILE" <<EOF
version=$PREVIOUS_CANVAS_VERSION
canvas_channel=stable/2026-04-08
canvas_commit=$PREVIOUS_CANVAS_COMMIT
canvas_tree=$PREVIOUS_CANVAS_TREE
canvas_archive_sha256=$PREVIOUS_CANVAS_SHA256
canvas_asset_patch_commit=$canvas_asset_patch_commit
canvas_asset_patch_sha256=$canvas_asset_patch_sha256
rce_channel=$PREVIOUS_RCE_VERSION
rce_commit=$PREVIOUS_RCE_COMMIT
rce_tree=$PREVIOUS_RCE_TREE
rce_archive_sha256=$PREVIOUS_RCE_SHA256
rce_runtime_dependency_fix=local-patch
rce_runtime_patch_sha256=$rce_runtime_patch_sha256
rce_passenger_sha256=$rce_passenger_sha256
ruby=$(ruby -e 'print RUBY_VERSION')
rails=$prior_rails_version
node=$(node --version)
yarn=$(yarn --version)
yarn_source=official-yarn-apt
EOF
    chmod 0644 "$SOURCE_FILE"

    prior_check=$(turnkey-canvas-update --check)
    require_contains "$prior_check" \
        "canvas_commit=$PREVIOUS_CANVAS_COMMIT" "prior Canvas updater check"
    require_contains "$prior_check" \
        "rce_commit=$PREVIOUS_RCE_COMMIT" "prior RCE updater check"
    require_contains "$prior_check" "candidate=$expected_canvas" \
        "prior Canvas updater check"
    require_contains "$prior_check" "candidate_tree=$expected_canvas_tree" \
        "prior Canvas updater check"
    require_contains "$prior_check" "candidate_rce=$expected_rce" \
        "prior RCE updater check"
    require_contains "$prior_check" \
        "candidate_rce_tree=$expected_rce_tree" "prior RCE updater check"
    require_contains "$prior_check" "status=update-available" \
        "prior Canvas updater check"

    apply_log=$stage/updater-apply.log
    turnkey-canvas-update --apply | tee "$apply_log"
    update_apply_log_sha256=$(sha256sum "$apply_log" | awk '{print $1}')
    apply_output=$(tail -n 4 "$apply_log")
    update_apply_backup_id=$(sed -n 's/^backup=//p' <<<"$apply_output")
    [[ $update_apply_backup_id =~ ^[0-9]{8}T[0-9]{6}Z$ ]] \
        || fail "Canvas updater apply did not return a backup identity"

    backup_root=/var/backups/turnkey-canvas
    db_backup=$backup_root/canvas-$update_apply_backup_id.sql.gz
    files_backup=$backup_root/canvas-$update_apply_backup_id-files.tar.gz
    [[ -s $db_backup && -s $files_backup ]] \
        || fail "Canvas updater apply did not create both backups"
    gzip -t "$db_backup" || fail "Canvas updater PostgreSQL backup is invalid"
    python3 - "$db_backup" "$update_prior_course_name" <<'PY' \
        || fail "Canvas updater PostgreSQL backup omitted preserved course data"
import gzip
import sys

needle = sys.argv[2].encode()
with gzip.open(sys.argv[1], "rb") as backup:
    if not any(needle in line for line in backup):
        raise SystemExit(1)
PY
    [[ $(tar -xOzf "$files_backup" \
        var/www/canvas/config/turnkey-updater-acceptance.yml \
        | sha256sum | awk '{print $1}') = \
        $(sha256sum "$APP_ROOT/config/turnkey-updater-acceptance.yml" \
        | awk '{print $1}') ]] \
        || fail "Canvas updater file backup omitted generated configuration"
    [[ $(tar -xOzf "$files_backup" var/www/canvas-rce-api/.env \
        | sha256sum | awk '{print $1}') = "$rce_env_hash" ]] \
        || fail "Canvas updater file backup omitted the RCE environment"
    tar -tzf "$files_backup" \
        var/www/canvas/tmp/files/turnkey-updater-acceptance.txt >/dev/null \
        || fail "Canvas updater file backup omitted stored file data"

    [[ $(config_manifest_sha256) = "$config_hash" ]] \
        || fail "Canvas updater changed generated Canvas configuration"
    [[ $(sha256sum "$RCE_ROOT/.env" | awk '{print $1}') = "$rce_env_hash" ]] \
        || fail "Canvas updater changed the RCE environment"
    [[ $(source_value canvas_commit) = "$expected_canvas" ]] \
        || fail "Canvas updater provenance did not record the applied commit"
    [[ $(source_value canvas_tree) = "$expected_canvas_tree" ]] \
        || fail "Canvas updater provenance did not record the applied tree"
    [[ $(source_value rce_commit) = "$expected_rce" ]] \
        || fail "Canvas updater provenance did not record the applied RCE commit"
    [[ $(source_value rce_tree) = "$expected_rce_tree" ]] \
        || fail "Canvas updater provenance did not record the applied RCE tree"
    echo "$rce_passenger_sha256  $RCE_ROOT/turnkey-passenger.js" \
        | sha256sum --check --status \
        || fail "Canvas updater did not restore the verified RCE launcher"

    systemctl is-active --quiet apache2 \
        || fail "Apache did not recover after Canvas updater apply"
    systemctl is-active --quiet postgresql \
        || fail "PostgreSQL did not recover after Canvas updater apply"
    systemctl is-active --quiet redis-server \
        || fail "Redis did not recover after Canvas updater apply"
    pgrep -u www-data -f 'delayed_job|inst_jobs' >/dev/null \
        || fail "Canvas jobs did not recover after updater apply"
    redis-cli ping | grep -qx PONG \
        || fail "Redis did not answer after Canvas updater apply"

    : > "$cookie"
    login_page=
    for _ in $(seq 1 60); do
        if login_page=$(curl "${curl_args[@]}" -L \
                "$BASE_URL/login/canvas" 2>/dev/null); then
            break
        fi
        sleep 5
    done
    require_contains "$login_page" "Canvas" "post-update Canvas login page"
    login_csrf_token=$(html_input_value authenticity_token <<<"$login_page") \
        || fail "post-update Canvas login form omitted its authenticity token"
    curl "${curl_args[@]}" -L "$BASE_URL/login/canvas" \
        -H "Referer: $BASE_URL/login/canvas" \
        --data-urlencode "authenticity_token=$login_csrf_token" \
        --data-urlencode "pseudonym_session[unique_id]=$LOGIN_EMAIL" \
        --data-urlencode "pseudonym_session[password]@$pass_file" \
        --data-urlencode 'pseudonym_session[remember_me]=0' \
        -o /dev/null
    dashboard=$(curl "${curl_args[@]}" "$BASE_URL/")
    require_contains "$dashboard" "Dashboard" \
        "post-update authenticated Canvas dashboard"
    csrf_token=$(cookie_value "$cookie" _csrf_token) \
        || fail "post-update Canvas session omitted its CSRF token"

    post_course_name='TurnKey Canvas post-update course'
    post_course_code='TKL-V19-POST'
    post_course_json=$(curl "${curl_args[@]}" \
        -H "X-CSRF-Token: $csrf_token" \
        -H 'Accept: application/json' \
        "$BASE_URL/api/v1/accounts/1/courses" \
        --data-urlencode "course[name]=$post_course_name" \
        --data-urlencode "course[course_code]=$post_course_code" \
        --data-urlencode 'course[is_public]=true' \
        --data-urlencode 'offer=true')
    post_course_id=$(python3 -c \
        'import json,sys; print(json.load(sys.stdin)["id"])' \
        <<<"$post_course_json")
    [[ $post_course_id =~ ^[0-9]+$ ]] \
        || fail "post-update Canvas API did not create a course"
    post_course_read=$(curl "${curl_args[@]}" -H 'Accept: application/json' \
        "$BASE_URL/api/v1/courses/$post_course_id")
    require_contains "$post_course_read" "$post_course_name" \
        "post-update Canvas course read response"
    post_course_page=$(curl "${curl_args[@]}" \
        "$BASE_URL/courses/$post_course_id")
    require_contains "$post_course_page" "$post_course_name" \
        "post-update Canvas course page"
    db_courses=$(su postgres -c \
        "psql --tuples-only --no-align canvas_production --command=\"SELECT name || '|' || course_code FROM courses WHERE id IN ($update_prior_course_id, $post_course_id) ORDER BY id\"")
    require_contains "$db_courses" \
        "$update_prior_course_name|$update_prior_course_code" \
        "post-update preserved PostgreSQL course"
    require_contains "$db_courses" "$post_course_name|$post_course_code" \
        "post-update new PostgreSQL course"

    asset_path=$(sed -n \
        's/.*href="\([^"]*\/dist\/[^"]*\.css[^"]*\)".*/\1/p' \
        <<<"$login_page" | head -n 1)
    [[ -n $asset_path ]] \
        || fail "post-update Canvas login omitted compiled CSS"
    asset_size=$(curl --insecure -fsSL --max-time 60 \
        "$BASE_URL$asset_path" | wc -c)
    [[ $asset_size -gt 100 ]] \
        || fail "post-update Canvas compiled CSS asset was empty"
    rce_body=
    for _ in $(seq 1 12); do
        if rce_body=$(curl --insecure -fsS --max-time 60 \
                https://localhost:3000/ 2>/dev/null); then
            break
        fi
        sleep 5
    done
    [[ -n $rce_body ]] \
        || fail "post-update Canvas RCE root did not return HTTP 200"
    require_contains "$rce_body" "Hello, from RCE Service" \
        "post-update Canvas RCE service"
    rce_readiness=$(curl --insecure -fsS --max-time 60 \
        https://localhost:3000/readiness) \
        || fail "post-update Canvas RCE readiness did not return HTTP 200"
    require_contains "$rce_readiness" '"name":"Rich Content Service"' \
        "post-update Canvas RCE readiness"

    update_post_check=$(turnkey-canvas-update --check)
    require_contains "$update_post_check" "canvas_commit=$expected_canvas" \
        "post-update Canvas updater check"
    require_contains "$update_post_check" "rce_commit=$expected_rce" \
        "post-update RCE updater check"
    require_contains "$update_post_check" "status=up-to-date" \
        "post-update Canvas updater check"

    case "$stage" in
        /var/tmp/turnkey-canvas-update-test.*) rm -rf -- "$stage" ;;
        *) fail "refusing to remove an unexpected updater fixture path" ;;
    esac
}
