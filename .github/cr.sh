#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

main() {
    install_chart_releaser

    rm -rf .cr-release-packages
    mkdir -p .cr-release-packages

    rm -rf .cr-index
    mkdir -p .cr-index
    RELEASE_NAME=$(yq -e '.name + "-" + .version' deploy/helm/Chart.yaml)
    NEW_TAG=$RELEASE_NAME
    
    # Generate release notes 
    if [[ "$RELEASE_NAME" == *"alpha"* ]]; then
        echo "Handling alpha release: $RELEASE_NAME"
        PREVIOUS_TAG=$(git tag --sort=version:refname | grep alpha | grep -B1 "^swo-k8s-collector" | tail -n 1)
    else
        echo "Handling standard release: $RELEASE_NAME"
        PREVIOUS_TAG=$(git tag --sort=version:refname | grep -v alpha | grep -B1 "^swo-k8s-collector" | tail -n 1)
    fi

    GIT_PATH="deploy"
    echo "# Changed:" > deploy/helm/release-notes.md
    git log "$PREVIOUS_TAG"..HEAD --pretty=format:"%s by %aN" -- $GIT_PATH | grep -v Merge | awk '{print "* " $0}' >> deploy/helm/release-notes.md
    echo "" >> deploy/helm/release-notes.md
    echo "**Full Changelog**: https://github.com/solarwinds/swi-k8s-opentelemetry-collector/compare/$PREVIOUS_TAG...$NEW_TAG" >> deploy/helm/release-notes.md
    echo "Release notes:"
    cat deploy/helm/release-notes.md


    echo "Packaging chart ..."
    cr package "deploy/helm"
    
    # Find the .tgz file and extract the release name
    RELEASE_FILE=$(find .cr-release-packages -name '*.tgz')
    

    echo "Release file: $RELEASE_FILE"

  
    
    echo 'Releasing chart...'
    cr upload -c "$(git rev-parse HEAD)" --release-notes-file=release-notes.md
    
    echo 'Updating chart repo index...'
    cr index

    echo 'Pushing update...'
    push_files "$RELEASE_NAME"

    echo 'Creating pull request...'
    create_pr "$RELEASE_NAME"
}

install_chart_releaser() {
    local version="v1.6.0"
    local install_dir="$RUNNER_TOOL_CACHE/cr/$version/$(uname -m)"
    if [[ ! -d "$install_dir" ]]; then
        mkdir -p "$install_dir"

        echo "Installing chart-releaser on $install_dir..."
        curl -sSLo cr.tar.gz "https://github.com/helm/chart-releaser/releases/download/$version/chart-releaser_${version#v}_linux_amd64.tar.gz"
        tar -xzf cr.tar.gz -C "$install_dir"
        rm -f cr.tar.gz
    fi

    echo 'Adding cr directory to PATH...'
    export PATH="$install_dir:$PATH"
}

push_files() {
    local release_name="$1"
    local branch_name="feature/${release_name}"
    local base_branch="gh-pages"

    # Fetch the latest state of the remote branches
    git fetch origin

    # Create a new branch from the latest commit of the gh-pages branch
    echo "Creating new branch '$branch_name' from '$base_branch'..."
    gh api -X POST /repos/solarwinds/swi-k8s-opentelemetry-collector/git/refs \
        --field ref="refs/heads/$branch_name" \
        --field sha="$(git rev-parse "origin/$base_branch")"

    # Get the SHA of the current index.yaml in the base branch
    SHA=$(gh api repos/solarwinds/swi-k8s-opentelemetry-collector/contents/index.yaml?ref="$base_branch" \
        --jq '.sha')

    MESSAGE="New release $release_name"

    # Push new index.yaml to the feature branch
    echo "Pushing new index.yaml to branch '$branch_name'..."
    gh api --method PUT /repos/solarwinds/swi-k8s-opentelemetry-collector/contents/index.yaml \
        --field message="$MESSAGE" \
        --field content=@<(base64 -i .cr-index/index.yaml) \
        --field branch="$branch_name" \
        --field sha="$SHA"
}

create_pr() {
    local release_name="$1"
    local branch_name="feature/${release_name}"
    local base_branch="gh-pages"

    # Create a pull request
    echo "Creating a pull request from '$branch_name' into '$base_branch'..."
    gh pr create --base "$base_branch" --head "$branch_name" \
        --title "Update Helm Chart for $release_name" \
        --body "This PR updates the Helm chart index.yaml with the latest release $release_name."
}

main "$@"
