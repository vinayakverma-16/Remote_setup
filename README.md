# Remote Support — Temporary SSH Access

Quick SSH access to on-site Linux PCs from your Windows office PC.  
**No VPS needed** — uses free tunneling (bore.pub).

---

## How It Works

```
You (Office PC)  ──SSH──▶  bore.pub  ◀──tunnel──  On-site PC
```

The on-site script opens a **reverse tunnel** through bore.pub so your office PC can SSH in.  
Everything is temporary — press Ctrl+C and it all cleans up.

---

## Quick Start

### Step 1: On the On-site PC (via Zoho Assist)

Copy-paste this one-liner:

```bash
curl -sL "https://workdrive.zohoexternal.in/external/0da09d68cafd8b91431c03bf446363daf846df8ae7d9b73d1ded0a86bd7a2abe/download" -o /tmp/site-setup.sh && sudo bash /tmp/site-setup.sh
```

Or if you have the script file locally:

```bash
sudo bash site-setup.sh
```


The script will:
1. ✅ Install & start SSH server (if needed)
2. ✅ Create a temporary user with a random password
3. ✅ Download `bore` and open a tunnel
4. ✅ Display the connection details

You'll see something like:

```
╔════════════════════════════════════════════════════════╗
║   🔗 REMOTE SUPPORT SESSION READY                     ║
╠════════════════════════════════════════════════════════╣
║                                                        ║
║   From your office PC, run:                           ║
║   ssh support_a3f8@bore.pub -p 54321                  ║
║                                                        ║
║   Password:  xK9mPq2vR7                              ║
╚════════════════════════════════════════════════════════╝
```

### Step 2: On Your Office PC (Windows)

**Option A** — Just run the SSH command directly:
```powershell
ssh support_a3f8@bore.pub -p 54321
```

**Option B** — Use the helper script (interactive prompts):
```powershell
.\office-connect.ps1
```

**Option C** — Use the helper with parameters:
```powershell
.\office-connect.ps1 -Host bore.pub -Port 54321 -User support_a3f8
```

### Step 3: When Done

Go back to Zoho Assist and press **Ctrl+C** on the running script.  
It will automatically:
- ❌ Kill the tunnel
- ❌ Delete the temp user
- ❌ Stop SSH server (if it wasn't running before)

---

## Alternative Tunnel Methods

### ngrok (more reliable, needs free account)

1. Install ngrok: https://ngrok.com/download
2. Set your auth token: `ngrok config add-authtoken YOUR_TOKEN`
3. Run: `sudo bash site-setup.sh ngrok`

### tmate (shared terminal, no full SSH)

Run: `sudo bash site-setup.sh tmate`

This gives a **shared terminal session** — the on-site person can see what you type.  
Good for pair-debugging, not for background work.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `bore: command not found` | Script auto-downloads it. If it fails, check internet connection. |
| `Connection refused` | SSH server might not be running. The script starts it automatically. |
| `Permission denied` | Double-check the password. It's case-sensitive. |
| Tunnel drops after a while | bore.pub is free and best-effort. Restart the script to get a new port. |
| `curl: command not found` | Install curl: `sudo apt install curl` or `sudo yum install curl` |
| Firewall blocking outbound | The on-site PC needs outbound access to bore.pub on port 7835. |

---

## Files

| File | Where | Purpose |
|------|-------|---------|
| `site-setup.sh` | On-site Linux PC | Sets up SSH + tunnel |
| `office-connect.ps1` | Your office Windows PC | Connects to the session |

---

## Security Notes

- The temp user + password are **randomly generated** each session
- The user is **deleted** when the script exits (Ctrl+C or crash)
- bore.pub tunnels are **ephemeral** — ports are reassigned each time
- The temp user has **sudo with password** — you need the temp password for sudo commands
- No ports are permanently opened on either machine
