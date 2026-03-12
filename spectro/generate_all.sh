#!/bin/bash

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

bash "$SCRIPTDIR/generate_controller.sh"
bash "$SCRIPTDIR/generate_webhook.sh"
