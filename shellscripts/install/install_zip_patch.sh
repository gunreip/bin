#!/bin/bash
set -euo pipefail
shopt -s nullglob

# Must be run from the project root
PROJECT_DIR="$(pwd)"
DOWNLOADS_DIR="$PROJECT_DIR/.downloads/downloads"
UNZIPPED_DIR="$PROJECT_DIR/.downloads/.unzipped"
LOGS_DIR="$PROJECT_DIR/.downloads/logs"
BACKUP_SUFFIX=".bak"

# Load .env if present
if [ -f "$PROJECT_DIR/.env" ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' "$PROJECT_DIR/.env" | xargs || true)
fi

mkdir -p "$DOWNLOADS_DIR" "$UNZIPPED_DIR" "$LOGS_DIR"

TODAY="$(date +%Y%m%d)"
LOG_FILE="$LOGS_DIR/LOG_${TODAY}.md"

# Create header if log doesn't exist yet
if [ ! -f "$LOG_FILE" ]; then
  echo "# Patch Installations-Log (${TODAY})" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"
fi

# Process all ZIPs dropped into .downloads/downloads/
for ZIP_FILE in "$DOWNLOADS_DIR"/*.zip; do
  [ -e "$ZIP_FILE" ] || continue

  ZIP_BASENAME="$(basename "$ZIP_FILE")"
  START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
  TMP_DIR="$PROJECT_DIR/.downloads/__tmp_unzip_$(date +%s)_$$"
  mkdir -p "$TMP_DIR"

  echo "${START_TS} | ZIP: ${ZIP_BASENAME}" >> "$LOG_FILE"

  # Unzip quietly
  unzip -q "$ZIP_FILE" -d "$TMP_DIR"

  cd "$TMP_DIR"
  # Iterate files within zip
  while IFS= read -r -d '' FILE; do
    REL="${FILE#./}"
    DEST="$PROJECT_DIR/$REL"
    DEST_DIR="$(dirname "$DEST")"
    mkdir -p "$DEST_DIR"

    TARGET_TILDE="${DEST/$HOME/~}"

    BACKUP_NOTE="none"
    if [ -f "$DEST" ]; then
      BACKUP_DIR="$DEST_DIR/.backup"
      mkdir -p "$BACKUP_DIR"
      TS="$(date +%Y%m%d_%H%M%S)"
      BASE="$(basename "$DEST")"
      BACKUP_PATH="$BACKUP_DIR/${BASE}_${TS}${BACKUP_SUFFIX}"
      mv "$DEST" "$BACKUP_PATH"
      BACKUP_NOTE="${BACKUP_PATH/$HOME/~}"

      # Keep max 5 backups per file
      mapfile -t EXISTING < <(ls -1t "$BACKUP_DIR"/"${BASE}"_*"$BACKUP_SUFFIX" 2>/dev/null || true)
      if [ "${#EXISTING[@]}" -gt 5 ]; then
        for ((i=5; i<${#EXISTING[@]}; i++)); do
          rm -f "${EXISTING[$i]}" || true
        done
      fi
    fi

    # Move the new file into place
    mkdir -p "$(dirname "$DEST")"
    mv "$FILE" "$DEST"

    echo "- Target: ${TARGET_TILDE}" >> "$LOG_FILE"
    echo "  Backup: ${BACKUP_NOTE}" >> "$LOG_FILE"
  done < <(find . -type f -print0)

  cd "$PROJECT_DIR"
  rm -rf "$TMP_DIR"

  # Archive the processed ZIP into .unzipped/ with collision-safe name
  ARCHIVE_PATH="$UNZIPPED_DIR/$ZIP_BASENAME"
  if [ -e "$ARCHIVE_PATH" ]; then
    ARCHIVE_PATH="$UNZIPPED_DIR/${ZIP_BASENAME%.zip}_$(date +%Y%m%d_%H%M%S).zip"
  fi
  mv "$ZIP_FILE" "$ARCHIVE_PATH"

  # Blank line as visual separator between ZIP runs
  echo "" >> "$LOG_FILE"
done

echo "Done."
