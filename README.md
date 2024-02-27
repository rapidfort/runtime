<a href="https://rapidfort.com?utm_source=github&utm_medium=ci_rf_link&utm_campaign=sep_01_sprint&utm_term=ci_main_landing&utm_content=main_landing_logo">
<img src="/contrib/github_logo.png" alt="RapidFort" width="200" />
</a>

<h1> RapidFort Runtime Release </h1>

Here you can download our RapidFort Runtime installation script and use this to install our Runtime tooling into your Kubernetes environment.

## Downloads

#### Mac (Darwin ARM64)
	curl -LO https://github.com/rapidfort/runtime/releases/download/1.0.22/rf-cmd-darwin-arm64 ; chmod a+x rf-cmd-darwin-arm64; sudo mv rf-cmd-darwin-arm64 /usr/local/bin/rf-cmd

#### Linux
	curl -LO https://github.com/rapidfort/runtime/releases/download/1.0.22/rf-cmd-linux-amd64 ; chmod a+x rf-cmd-linux-amd64; sudo mv rf-cmd-linux-amd64 /usr/local/bin/rf-cmd

## Usage

#### Deploy for SaaS
	rf-cmd --cmd install -u <username> -p <password>	

#### Deploy for On-Prem
	rf-cmd --cmd install -h <rf_host> -u <username> -p <password> -ru <registry-username> -rp <registry-password> 
 
#### Uninstall
	rf-cmd --cmd uninstall


## Need Support

<a href="https://join.slack.com/t/rapidfortcommunity/shared_invite/zt-1g3wy28lv-DaeGexTQ5IjfpbmYW7Rm_Q">
<img src="/contrib/github_banner.png" alt="RapidFort Community Slack" width="600" />
</a>
