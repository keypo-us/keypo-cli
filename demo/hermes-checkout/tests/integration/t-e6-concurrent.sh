#!/bin/bash
# T-E6: Concurrent requests serialized
echo "=== T-E6: Concurrent requests serialized ==="
echo "MANUAL: Two terminal sessions send buy requests simultaneously."
echo "Expected: First proceeds. Second gets 'already staged' error from daemon."
echo "SKIP: manual integration test"
