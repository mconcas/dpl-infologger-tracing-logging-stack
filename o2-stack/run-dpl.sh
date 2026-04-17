#!/bin/bash

export IL_SOCKET_PATH=/tmp/infologger-socket/infologgerD.sock
export DPL_LOAD_SERVICES="O2FrameworkDataTakingSupport:InfoLoggerContext,O2FrameworkDataTakingSupport:InfoLogger"
export O2_INFOLOGGER_MODE=infoLoggerD
export INFOLOGGER_TRANSPORT="infoLoggerD://${IL_SOCKET_PATH}"
export O2_INFOLOGGER_CONFIG=file:/tmp/infologger.cfg
export ALIBUILD_WORK_DIR="/home/alice/sw"
eval "$(alienv shell-helper)"


# Write configuration from environment variables
cat > /tmp/infologger.cfg <<EOF
[client]
txSocketPath=${IL_SOCKET_PATH}
EOF

alienv setenv O2/latest-otel-tracing-o2 -c o2-testworkflows-diamond-workflow -b --run --shm-segment-size 20000000 --infologger-severity info --tracing-backend otlp-grpc://otel-collector:4317