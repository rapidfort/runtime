<a href="https://rapidfort.com?utm_source=github&utm_medium=ci_rf_link&utm_campaign=sep_01_sprint&utm_term=ci_main_landing&utm_content=main_landing_logo">
<img src="/contrib/github_logo.png" alt="RapidFort" width="200" />
</a>

<h1> RapidFort Runtime Release </h1>

Here you can download our RapidFort Runtime installation script and use this to install our Runtime tooling into your Kubernetes environment.

## Downloads

#### Mac (Darwin ARM64)
	wget https://github.com/rapidfort/runtime/releases/download/1.0.21/rf-cmd-darwin-arm64 ; chmod +x rf-cmd-darwin-arm64; sudo mv rf-cmd-darwin-arm64 /usr/local/bin/rf-cmd

#### Linux
	wget https://github.com/rapidfort/runtime/releases/download/1.0.21/rf-cmd-linux-amd64 ; chmod +x rf-cmd-linux-amd64; sudo mv rf-cmd-linux-amd64 /usr/local/bin/rf-cmd

## Usage

#### Install for SAAS
	rf-cmd -cmd install --rev 1.0.21-61 -u <username> -p <password> -t 1.0.21-1785bca-61-rfhardened	

#### Install for On-Prem
	rf-cmd -cmd install --rev 1.0.21-61 -t 1.0.21-1785bca-61-rfhardened -h <rf_host> -u <username> -p <password> -ru <registry-username> -rp <registry-password> 
 
#### Uninstall
	rf-cmd -cmd uninstall


## Need Support

<a href="https://join.slack.com/t/rapidfortcommunity/shared_invite/zt-1g3wy28lv-DaeGexTQ5IjfpbmYW7Rm_Q">
<img src="/contrib/github_banner.png" alt="RapidFort Community Slack" width="600" />
</a>
