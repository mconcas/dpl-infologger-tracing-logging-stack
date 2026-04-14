#!/bin/bash

export DPL_LOAD_SERVICES="O2FrameworkDataTakingSupport:InfoLoggerContext,O2FrameworkDataTakingSupport:InfoLogger"
export O2_INFOLOGGER_MODE=infoLoggerD
export INFOLOGGER_TRANSPORT="infoLoggerD:///tmp/infologger-socket/infologgerD.sock"
export O2_INFOLOGGER_CONFIG=file:/tmp/infologger.cfg
# export O2_INFOLOGGER_OPTIONS="verbose=1,outputModeFallback=none"

o2-testworkflows-diamond-workflow -b --run --shm-segment-size 20000000 --infologger-severity info