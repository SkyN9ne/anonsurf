import os
import strutils
import net
import sequtils
import .. / anonsurf / cores / commons / [dns_utils, services_status]
import posix

const
  sysResolvConf = "/etc/resolv.conf"
  bakResolvConf = "/etc/resolv.conf.bak"
  runResolvConf = "/run/resolvconf/resolv.conf"
  # dhcpResolvConf = "/run/resolvconf/interface/NetworkManager"
  tailResolvConf = "/etc/resolvconf/resolv.conf.d/tail"


proc getResolvConfAddresses(): seq[string] =
  for line in lines(sysResolvConf):
    if line.startsWith("nameserver"):
      result.add(line.split(" ")[1])


proc showHelpCmd(cmd = "dnstool", keyword = "help", args = "", descr = "") =
  #[
    Make color for command syntax in help bannner
    Print them in help
    Syntax: <command> <keyword> <args> [<description>]
    command -> light green
    keyword -> red
    args (optional) -> yellow
    description (optional) -> blue
  ]#
  var cmdOutput = ""
  cmdOutput &= "\e[92m" & cmd & "\e[0m " # Green color for command
  cmdOutput &= "\e[91m" & keyword & "\e[0m " # Red color for keyword
  if args != "":
    cmdOutput &= "\e[93m" & args & "\e[0m "
  if descr != "":
    cmdOutput &= "[\e[94m" & descr & "\e[0m]"
  
  echo cmdOutput


proc banner() =
  stdout.write("DNS Tool: A CLI tool to change DNS settings quickly\n")
  stdout.write("Developer: Nong Hoang \"DmKnght\" Tu <dmknght@parrotsec.org>\n")
  stdout.write("Gitlab: https://nest.parrot.sh/packages/tools/anonsurf\n")
  stdout.write("License: GPL3\n\n")


proc showHelpDesc(keyword = "", descr = "") =
  #[
    Make color for description
    syntax:
      <keyword>: <description>
    keyword -> red
    description -> blue
  ]#
  var helpDesc = ""
  if keyword != "":
    helpDesc = "\e[91m" & keyword & "\e[0m: "
  helpDesc &= "\e[94m" & descr & "\e[0m"

  echo "  " & helpDesc


proc help() =
  banner()
  # let progName = getAppFileName()
  let progName = "dnstool"
  showHelpCmd(cmd = progName, keyword = "help | -h | --help", descr = "Show help banner")
  showHelpCmd(cmd = progName, keyword = "status", descr = "Show current system DNS")
  showHelpCmd(cmd = "sudo " & progName, keyword = "address", args = "<DNS servers>" , descr = "Set DNS servers") # TODO improve msg quality here
  showHelpCmd(cmd = "sudo " & progName, keyword = "create-backup", descr = "Make backup for current /etc/resolv.conf")
  showHelpCmd(cmd = "sudo " & progName, keyword = "restore-backup", descr = "Restore backup of /etc/resolv.conf")
  stdout.write("\nAddress could be:\n")
  showHelpDesc(keyword = "dhcp", descr = "Address[es] of current DHCP client.")
  showHelpDesc(descr = "Any IPv4 or IPv6 address[es]")
  stdout.write("\nStatic file and Symlink:\n")
  showHelpDesc(keyword = "Symlink", descr = sysResolvConf & " is a symlink of " & runResolvConf)
  showHelpDesc(keyword = "Static file", descr = sysResolvConf & " is not a symlink and won't be changed after reboot.")
  stdout.write("\n")


proc printErr(msg: string) =
  # Print error with color red
  echo "[\e[31m!\e[0m] \e[31m", msg, "\e[0m"


# proc getDhcpDNS(): string =
#   return readFile(dhcpResolvConf) & "\n"


proc lnkResovConf() =
  #[
    Create a symlink of /etc/resolv.conf from
    /run/resolvconf/resolv.conf
    FIXME if the system has the 127.0.0.1 in runResolvConf
  ]#
  try:
    createSymlink(runResolvConf, sysResolvConf)
  except:
    printErr("Failed to create symlink from " & sysResolvConf)


proc writeTail(dnsAddr: string) =
  #[
    Create dyanmic resolv.conf
    Write tail
  ]#
  try:
    if getuid() == 0:
      writeFile(tailResolvConf, dnsAddr)
    else:
      printErr("User ID is not 0. Did you try sudo?")
  except:
    printErr("Failed to write addresses to Tail")


proc writeResolv(dnsAddr: string) =
  #[
    Create static resolv.conf
  ]#
  let banner = "# Static resolv.conf generated by DNSTool\n# Settings wont change after reboot\n"
  try:
    if getuid() == 0:
      writeFile(sysResolvConf, banner & dnsAddr)
    else:
      printErr("User ID is not 0. Did you try sudo?")
  except:
    printErr("Failed to create new resolv.conf")


proc makeDHCPDNS() =
  try:
    removeFile(sysResolvConf)
    writeTail("")
    lnkResovConf()
  except:
    printErr("Failed to generate DHCP addresses")


proc handleMakeDNS(dnsAddr: seq[string]) =
  try:
    var dns_to_write = ""
    for address in dnsAddr:
      dns_to_write &= "nameserver " & address & "\n"
    # Remove old resolv.conf
    removeFile(sysResolvConf)
    # Remove old addresses in tail
    writeTail("")
    writeResolv(dns_to_write)
  except:
    printErr("Failed to write settings to resolv.conf")


proc mkBackup() =
  #[
    Backup current settings of /etc/resolv.conf
    to /etc/resolv.conf.bak
  ]#
  # Check previous backup exists
  # Check current settings
  # skip if it is localhost or error of /etc/resolv.conf
  # or symlink
  let status = dnsStatusCheck()
  if status <= 0:
    # We are having error -> skip
    discard
  else:
    let resolvConfInfo = getFileInfo(sysResolvConf, followSymlink = false)
    # If resolv.conf is not a symlink (dynamic), we don't backup it
    if resolvConfInfo.kind != pcLinkToFile:
      if getuid() == 0:
        try:
          copyFile(sysResolvConf, bakResolvConf)
          echo "Backup file created at ", bakResolvConf
        except:
          printErr("Failed to create backup file for resolv.conf")
      else:
        printErr("User ID is not 0. Did you try sudo?")


proc restoreBackup() =
  #[
    Restore /etc/resolv.conf.bak to /etc/resolv.conf
    Or use dhcp addresses
  ]#
  let status = dnsStatusCheck()
  if status == STT_DNS_TOR:
    # AnonSurf is running so it is using localhost. skip
    return
  if not fileExists(bakResolvConf):
    # No backup file. We create DHCP + dynamic setting
    # If there is no resolv.conf, we create symlink
    # If there is resolv.conf:
    # Create dhcp setting only DNS is localhost
    if fileExists(sysResolvConf):
      if status != ERROR_DNS_LOCALHOST:
        return
      makeDHCPDNS()
    else:
      lnkResovConf()
  else:
    # If resolv.conf not found, we force creating DHCP
    if status == ERROR_FILE_NOT_FOUND:
      makeDHCPDNS()
    # Else we have resolv.conf and its backup file
    else:
      # First force removing old resolv.conf
      # Solve the symlink error while writing new file
      if tryRemoveFile(sysResolvConf):
        moveFile(bakResolvConf, sysResolvConf)
      else:
        discard # TODO show error here


proc showStatus() =
  #[
    Get current settings of DNS on system
  ]#

  if fileExists(sysResolvConf):
    let resolvFileType = if getFileInfo(sysResolvConf).kind == pcLinkToFile: "Symlink" else: "Static file"
    stdout.write("[\e[32mSTATUS\e[0m]\n- \e[31mMethod\e[0m: \e[36m" & resolvFileType & "\e[0m\n")
    
    let addresses = getResolvConfAddresses()
    let is_surf_running = if getServStatus("anonsurfd") == 0: true  else: false

    if addresses == []:
      stderr.write("[\e[31mDNS error\e[0m] resolv.conf is empty\n")
    # If anonsurf is running. Check by status instead
    elif is_surf_running:
      stdout.write("- \e[31mAddress\e[0m: AnonSurf is running\n")
      var is_other_dns_addr = false
      for address in addresses:
        if address == "127.0.0.1" or address == "localhost":
          stdout.write("  " & address & " \e[32mUsing Tor's DNS\e[0m\n")
        else:
          is_other_dns_addr = true
          stdout.write("  " & address & " \e[31mNot a Tor DNS server.\e[0m\n")
      if is_other_dns_addr:
        stderr.write("\e[31m\nDetected Non-Tor address[es]. This may cause information leaks.\e[0m\n")
    else:
      stdout.write("- \e[31mAddress\e[0m:\n")
      for address in addresses:
        if address == "127.0.0.1" or address == "localhost":
          stdout.write("  " & address & " \e[31mLocalHost. This may cause no internet access\e[0m\n")
        else:
          stdout.write("  " & address & "\n")
  else:
    stderr.write("[\e[31mDNS error\e[0m] File \e[31mresolv.conf\e[0m not found\n")


proc main() =
  if paramCount() == 0:
    help()
    showStatus()
  elif paramCount() == 1:
    if paramStr(1) in ["help", "-h", "--help", "-help"]:
      help()
    elif paramStr(1) == "status":
      showStatus()
    elif paramStr(1) == "create-backup":
      mkBackup()
    elif paramStr(1) == "restore-backup":
      restoreBackup()
      showStatus()
    else:
      stderr.write("[!] Invalid option\n")
  else:
    if paramStr(1) == "address":
      if paramStr(2) == "dhcp":
        makeDHCPDNS()
      else:
        var
          dnsAddr: seq[string]
        for i in 2 .. paramCount():
          if paramStr(i) == "--add":
            let current_addresses = getResolvConfAddresses()
            if current_addresses != [] and current_addresses != ["localhost"] and current_addresses != ["127.0.0.1"]:
              for address in getResolvConfAddresses():
                dnsAddr = dnsAddr.concat(current_addresses)
          else:
            dnsAddr.add(paramStr(i))

        handleMakeDNS(deduplicate(dnsAddr))
      showStatus()
      stdout.write("\n[*] Applied DNS settings\n")
    else:
      help()
      stderr.write("[!] Invalid option\n")
      return    


main()
