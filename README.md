# sMirror Backend Releases

This is just the repository holding the backend releases for sMirror. The actual backend code is hosted on GitLab, but it is currently **closed-source**.

### Why not open source the backend?
The reason is everything going on with AI right now. The big players have decided to go the bad route, and no one is respecting licenses anymore. This goes beyond just model training—there is a massive issue with AI simply copy-pasting and laundering code.

However, this isn't necessarily a permanent decision. The backend can go open-source in the future once the current AI landscape stabilizes and there are actually reliable, enforceable legal frameworks to protect intellectual property.

### The Open-Source Flutter Ecosystem
But don't worry, the Flutter parts are completely open-source! The current architecture allows you to easily contribute your own widgets and implement any API you want. You only need to adapt the frontend and the app:

* [smirrorFrontend](https://github.com/thearrogantdev/smirrorFrontend.git)
* [smirrorApp](https://github.com/thearrogantdev/smirrorApp.git)

---

## 🚀 Quick Start

All you need to do is execute `install.sh` from our scripts folder. Just do the following two commands:

```bash
sudo apt update && sudo apt install -y curl
```

```bash
curl -fsSL https://raw.githubusercontent.com/thearrogantdev/smirrorBackend/main/scripts/install.sh | sudo bash
```