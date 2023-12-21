# runtime
RapidFort runtime releases

## download

### MAC
	wget https://github.com/rapidfort/runtime/releases/download/1.0.20/rf-cmd-darwin-arm64; chmod +x rf-cmd-darwin-arm64; sudo mv rf-cmd-darwin-arm64 /usr/local/bin/rf-cmd

### Linux
	wget https://github.com/rapidfort/runtime/releases/download/1.0.20/rf-cmd-linux-amd64; chmod +x rf-cmd-linux-amd64; sudo mv rf-cmd-linux-amd64 /usr/local/bin/rf-cmd

## usage
	./rf-cmd -h us01.rapidfort.com -u <username> -p <password> -r quay.io/rapidfort -c cri -ru <registry-username> -rp <registry-password> --rev 1.0.20
