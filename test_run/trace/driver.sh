#!/bin/bash
exec 7>>/workspace/test_run/trace/trace.log
export BASH_XTRACEFD=7
. /workspace/test_run/harness_inst.sh
. /workspace/test_run/trace/cases_collect.sh
