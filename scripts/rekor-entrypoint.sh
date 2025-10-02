#!/bin/sh
#
# Copyright 2025 The Sigstore Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

# Enable debug mode if DEBUG environment variable is set
DEBUG=${DEBUG:-0}
[ "$DEBUG" = "1" ] && set -x

# Configurable timeout and retry settings
MYSQL_WAIT_TIMEOUT=${MYSQL_WAIT_TIMEOUT:-60}
MYSQL_RETRY_INTERVAL=${MYSQL_RETRY_INTERVAL:-2}

# Check if first argument is "rekor-server", if not, prepend it
# This makes the script compatible with both "rekor-server serve ..." and "serve ..." formats
EXEC_CMD="rekor-server"
if [ "$1" = "rekor-server" ]; then
    # Already has rekor-server, shift it out
    shift
fi

# Extract MySQL connection parameters from the command line arguments
MYSQL_DSN=""
for arg in "$@"; do
    case $arg in
        --search_index.mysql.dsn=*)
            MYSQL_DSN="${arg#*=}"
            break
            ;;
    esac
done

# Parse MySQL DSN (format: user:password@tcp(host:port)/database)
# NOTE: Password should not contain special characters like : @ ( ) /
# If special characters are needed, consider URL encoding or using environment variables
if [ -n "$MYSQL_DSN" ]; then
    # Extract user, password, host, port, and database from DSN
    MYSQL_USER=$(echo "$MYSQL_DSN" | sed 's/^\([^:]*\):.*/\1/')
    MYSQL_PASS=$(echo "$MYSQL_DSN" | sed 's/^[^:]*:\([^@]*\)@.*/\1/')
    MYSQL_HOST=$(echo "$MYSQL_DSN" | sed 's/.*@tcp(\([^:]*\):.*/\1/')
    MYSQL_PORT=$(echo "$MYSQL_DSN" | sed 's/.*@tcp([^:]*:\([^)]*\)).*/\1/')
    MYSQL_DB=$(echo "$MYSQL_DSN" | sed 's/.*)\///')

    # Validate parsed DSN components
    if [ -z "$MYSQL_USER" ] || [ -z "$MYSQL_PASS" ] || [ -z "$MYSQL_HOST" ] || [ -z "$MYSQL_PORT" ] || [ -z "$MYSQL_DB" ]; then
        echo "Error: Failed to parse MySQL DSN. Expected format: user:password@tcp(host:port)/database"
        echo "Parsed values - User: '$MYSQL_USER', Host: '$MYSQL_HOST', Port: '$MYSQL_PORT', DB: '$MYSQL_DB'"
        exit 1
    fi

    echo "Checking for existing Trillian tree in database..."
    start_time=$(date +%s)

    # Set MySQL password via environment variable to avoid exposing it in process list
    export MYSQL_PWD="$MYSQL_PASS"

    # Wait for MySQL to be ready
    max_attempts=$((MYSQL_WAIT_TIMEOUT / MYSQL_RETRY_INTERVAL))
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -e "SELECT 1" >/dev/null 2>&1; then
            echo "MySQL is ready"
            break
        fi
        attempt=$((attempt + 1))
        echo "Waiting for MySQL to be ready... ($attempt/$max_attempts)"
        sleep $MYSQL_RETRY_INTERVAL
    done

    # Check if MySQL became ready
    if [ $attempt -ge $max_attempts ]; then
        echo "Error: MySQL did not become ready after $max_attempts attempts (timeout: ${MYSQL_WAIT_TIMEOUT}s)"
        unset MYSQL_PWD
        exit 1
    fi

    # Check for multiple active trees
    TREE_COUNT=$(mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" "$MYSQL_DB" -sN -e "SELECT COUNT(*) FROM Trees WHERE TreeState='ACTIVE'" 2>/dev/null || echo "0")
    if [ "$TREE_COUNT" -gt 1 ]; then
        echo "Warning: Found $TREE_COUNT active trees in database, using the most recent one"
    fi

    # Query for existing active tree
    EXISTING_TREE=$(mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" "$MYSQL_DB" -sN -e "SELECT TreeId FROM Trees WHERE TreeState='ACTIVE' ORDER BY CreateTimeMillis DESC LIMIT 1" 2>/dev/null || echo "")

    # Clean up password from environment
    unset MYSQL_PWD

    if [ -n "$EXISTING_TREE" ]; then
        elapsed=$(($(date +%s) - start_time))
        echo "Found existing tree with ID: $EXISTING_TREE (detection took ${elapsed}s)"
        # Check if --trillian_log_server.tlog_id is already in arguments
        TLOG_ID_EXISTS=0
        for arg in "$@"; do
            case $arg in
                --trillian_log_server.tlog_id=*)
                    TLOG_ID_EXISTS=1
                    break
                    ;;
            esac
        done

        if [ $TLOG_ID_EXISTS -eq 0 ]; then
            echo "Adding --trillian_log_server.tlog_id=$EXISTING_TREE to arguments"
            exec $EXEC_CMD "$@" --trillian_log_server.tlog_id="$EXISTING_TREE"
        else
            echo "Tree ID already specified in arguments, using that value"
            exec $EXEC_CMD "$@"
        fi
    else
        echo "No existing tree found, will create a new one"
        exec $EXEC_CMD "$@"
    fi
else
    echo "No MySQL DSN found in arguments, starting without tree ID check"
    exec $EXEC_CMD "$@"
fi
