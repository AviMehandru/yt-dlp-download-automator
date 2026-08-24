# yt-dlp-download-automator
This repository houses the files that are used to automate the downloading of youtube videos with yt-dlp; it includes some advanced configs and scripts to fully automate the process. 

To begin, first download all of these files and copy them into a folder. 

Next, download and install a virtual machine hypervisor onto whatever computer you use. 
I personally used and have tested VMware Workstation Pro (confirmed to be compatible in version 26H1) on my PC. 

After that, download the latest version of Ubuntu. This has been tested up to version 26.04. 
Install Ubuntu on your virtual machine hypervisor. 
Additionally, set up a shared folder between the two machines, using your hypervisor settings. 

After this, run this command: 

```
sudo apt install curl && curl -sSL https://raw.githubusercontent.com/AviMehandru/yt-dlp-download-automator/refs/heads/main/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh && rm setup.sh
```

Once that is installed, ensure that in your `/home/[username]/yt-dlp/configs` folder, there is a file called `yt-dlp.conf`. 
Additionally, there should be three files (`postprocess.ps1`, `run_ytdlp.ps1`, and `ytdl` in the folder `/home/[username]/yt-dlp/scripts`. 

You may want to bookmark the shared folder and `yt-dlp`. 
Additionally, if you want the output to get saved somewhere outside the default `/home/[username]/yt-dlp`, set up that folder and bookmark it too. 

Finally, execute this command: 

```
ytdl [Youtube URL] [Destination Path]
```

The `[Destination Path]` is optional, and if you don't use it, the videos will get saved to the default location (`/home/[username]/yt-dlp`). 

Before you execute any of these commands though, just go over all of the scripts and configs yourself to ensure that they are safe to run. 

Disclaimer: the majority of this code was generated with Claude Sonnet 5, with a small, initial amount of help by ChatGPT. More on this in the CREDITS.md file. 
