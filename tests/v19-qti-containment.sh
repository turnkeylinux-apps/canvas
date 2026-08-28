#!/bin/bash

# Focused regression for the appliance patch on the pinned legacy QTI importer.

exercise_qti_path_containment() {
    local fixture_root normal_input normal_output traversal_input traversal_output
    local negative_log marker

    fixture_root=$(mktemp -d /var/tmp/turnkey-canvas-qti-containment.XXXXXX)
    normal_input=$fixture_root/normal-input
    normal_output=$fixture_root/normal-output
    traversal_input=$fixture_root/traversal-input
    traversal_output=$fixture_root/traversal-output
    negative_log=$fixture_root/traversal.log
    marker=TURNKEY-BENIGN-QTI-OUTSIDE-ROOT-SENTINEL
    install -d "$normal_input" "$traversal_input"
    install -m 0644 /run/tkl-v19-tests/tests/fixtures/qti/normal.xml \
        "$normal_input/normal.xml"
    install -m 0644 \
        /run/tkl-v19-tests/tests/fixtures/qti/traversal/imsmanifest.xml \
        "$traversal_input/imsmanifest.xml"
    printf '%s\n' "$marker" > "$fixture_root/outside-root-sentinel.txt"

    "$APP_ROOT/vendor/QTIMigrationTool/migrate.py" --nogui \
        --cpout="$normal_output" "$normal_input"
    grep -RFlq 'Is this import contained?' "$normal_output/assessmentItems" \
        || fail "normal in-root QTI fixture was not converted"

    if "$APP_ROOT/vendor/QTIMigrationTool/migrate.py" --nogui \
            --cpout="$traversal_output" "$traversal_input" \
            >"$negative_log" 2>&1; then
        fail "out-of-root QTI source reference was accepted"
    fi
    grep -Fq 'QTI source reference leaves import root' "$negative_log" \
        || fail "out-of-root QTI source rejection was not explicit"
    ! grep -RFlq "$marker" "$traversal_output" 2>/dev/null \
        || fail "out-of-root QTI sentinel appeared in converted output"

    rm -rf "$fixture_root"
}
