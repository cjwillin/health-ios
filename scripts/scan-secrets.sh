#!/usr/bin/env bash
# secret-scan: fails (exit 1) if any tracked file matches a secret/token/key
# filename pattern or content regex. Run in CI and locally:
#   bash scripts/scan-secrets.sh
set -u

fail=0

# --- 1. Filename patterns -----------------------------------------------------
# (the scanner's own files are exempt from the *filename* check, not the content check)
name_re='(secret|token|credential|apikey|api_key|passkey|\.pem$|\.p12$|\.pfx$|\.jks$|\.keystore$|\.kdbx$|id_rsa|id_ed25519|id_ecdsa|\.env$|\.env\.|\.htpasswd$)'
while IFS= read -r f; do
    case "$f" in
        .github/workflows/secret-scan.yml|scripts/scan-secrets.sh) continue ;;
    esac
    if printf '%s' "$f" | grep -Eqi "$name_re"; then
        echo "FAIL filename pattern: $f"
        fail=1
    fi
done < <(git ls-files)

# --- 2. Content patterns ------------------------------------------------------
# Deliberately require a quote right after "name:" / "name=" so workflow files
# referencing secret *names* (e.g. GITHUB_TOKEN: ${{ secrets.X }}) do not match,
# while hardcoded quoted values do.
value_after_name="(secret|token|password|passwd|api[_-]?key|apikey)[[:space:]]*[:=][[:space:]]*[\"'][^\"']{8,}"
short_pass_value="(password|passwd)[[:space:]]*[:=][[:space:]]*[\"'][^\"']{4,}"
content_res=(
    "$value_after_name"
    "$short_pass_value"
    'AKIA[0-9A-Z]{16}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'gh[posu]_[A-Za-z0-9]{36,}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    'sk-(ant-)?[A-Za-z0-9_-]{20,}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'AIza[0-9A-Za-z_-]{35}'
)
while IFS= read -r f; do
    case "$f" in
        *.png|*.jpg|*.jpeg|*.gif|*.ico|*.zip|*.ipa|*.pdf|*.der|*.cer) continue ;;
    esac
    [ -f "$f" ] || continue
    for re in "${content_res[@]}"; do
        if grep -Eqi -- "$re" "$f" 2>/dev/null; then
            echo "FAIL content pattern [$re]: $f"
            fail=1
        fi
    done
done < <(git ls-files)

if [ "$fail" -ne 0 ]; then
    echo "secret-scan: FAILED (see lines above)"
    exit 1
fi
echo "secret-scan: OK ($(git ls-files | wc -l) tracked files clean)"
