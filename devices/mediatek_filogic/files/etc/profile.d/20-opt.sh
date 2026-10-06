#!/bin/sh
export PATH="/opt/usr/bin:/opt/usr/sbin:/opt/bin:/opt/sbin:$PATH"
export LD_LIBRARY_PATH="/opt/lib:/opt/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
