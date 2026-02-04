#!/bin/zsh

# Add Homebrew Ruby to PATH
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"

# Add Homebrew Gems to PATH
export PATH="/opt/homebrew/lib/ruby/gems/4.0.0/bin:$PATH"

# Add Flutter to PATH
export PATH="$HOME/code/p4td/tools/flutter/bin:$PATH"

# Verify setup
echo "Environment Configured:"
echo "Flutter: $(which flutter)"
echo "Pod: $(which pod)"
echo "Ruby: $(which ruby)"
