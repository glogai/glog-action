# glog-action Composite GitHub Action

`glog-action` is a GitHub Composite Action that enables seamless scanning using Glog.AI. 


## Supported Languages

  - C++
  - Java
  - JavaScript
  - Python
  - Kotlin
  - PHP
  - Go
  - Ruby
  - Swift
  - C#
    
### Other

  - OSS
  - PHP
  - Git
  - Terraform

## Features

 - <b>Integrated Workflow:</b> Easily integrate into your GitHub Actions workflow to automate the security analysis process.
 - <b>Comprehensive Language Support:</b> Analyze source code in multiple languages to identify potential security vulnerabilities.
 - <b>SARIF Output:</b> Generates a .sarif file containing the results of the analysis, which can be uploaded to the GitHub Security page for projects utilizing GitHub Advanced Security.

## Usage

 - <b>Setup the GitHub Action:</b> Integrate Glog.AI SAST tool into your repository's build action by including it as a step in your GitHub Actions YAML file.
 - <b>Run the Analysis:</b> Trigger the action, which will compile your source code and perform the security analysis.
 - <b>Review the Results:</b> Output is generated in SARIF format. If you are using GitHub Advanced Security, upload the .sarif file to the GitHub Security page to review detailed security findings.

To use this action, include the following configuration in your GitHub Actions workflow:

```yaml
name: Glog.AI Scan

on: 
  workflow_dispatch:

jobs:
  glog-scan-job:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Checkout glog-action repository
        uses: actions/checkout@v4
        with:
          repository: glogai/glog-action
          token: ${{ secrets.PAT_TOKEN }}
          path: .github/glog-action
          ref: main

      - name: Run Glog.AI from private repo
        uses: ./.github/glog-action
        with:
          lang: 'python'
          debug: 'false'
          client: 'demo'
          upload: 'false'
          env: 'dev'
          issue: true
          autofix: true
          max-issues: 30
          max-assign: 30
          github-token: ${{ secrets.PAT_TOKEN }}
          glog-token: ${{ secrets.GLOG_TOKEN }}
```

### Inputs

&nbsp;&nbsp;&nbsp;&nbsp;lang: The language to scan (e.g., "python"). \
&nbsp;&nbsp;&nbsp;&nbsp;debug: Enable or disable debug mode ("true"/"false"). \
&nbsp;&nbsp;&nbsp;&nbsp;client: Client name. \
&nbsp;&nbsp;&nbsp;&nbsp;upload: Enable or disable uploading results ("true"/"false"). \
&nbsp;&nbsp;&nbsp;&nbsp;env: Environment name. \
&nbsp;&nbsp;&nbsp;&nbsp;issue: Enable or disable uploading Glog issues as Github issues. ("true"/"false"). Not required. \
&nbsp;&nbsp;&nbsp;&nbsp;autofix: Enable or disable automatically create PR for the issues found ("true"/"false"). Not required. \
&nbsp;&nbsp;&nbsp;&nbsp;max-issues: Maximum number of SARIF findings to convert into GitHub issues per run. Not required. \
&nbsp;&nbsp;&nbsp;&nbsp;max-assign: Maximum number of created issues to assign to Copilot for autofix. Not required. \
&nbsp;&nbsp;&nbsp;&nbsp;github-token: GitHub Personal Access Token with repository access. \
&nbsp;&nbsp;&nbsp;&nbsp;glog-token: Token for authenticating with the Glog.AI service. \

### Setup

Secrets: \
    &nbsp;&nbsp;&nbsp;&nbsp;PAT_TOKEN: Personal Access Token for accessing repositories. \
    &nbsp;&nbsp;&nbsp;&nbsp;GLOG_TOKEN: Token for interacting with the Glog.AI service.

## Support

For support, open an issue or contact the maintainers at info@glog.ai.
