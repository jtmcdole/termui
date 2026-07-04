find . -type f \( -name "*.dart" -o -name "*.md" -o -name "*.yaml" \) -exec sed -i 's/[[:space:]]*$//' {} +
