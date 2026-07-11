find . -type f \( -name "*.dart" -o -name "*.md" -o -name "*.yaml" -o -name "*.yml" \) -exec sed -i 's/[[:space:]]*$//' {} +
