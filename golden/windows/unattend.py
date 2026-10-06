#!/usr/bin/env python3
"""Render the two answer files of the Windows golden build from the base ISO's own autounattend.xml
(windows/image/autounattend.xml with the OEM model filled in by windows/build/Build-Image.ps1).

    unattend.py build   ISO_AUTOUNATTEND OUT   Setup in the build VM: wipes the VM's only disk (an
                                               NVMe), installs Windows 11 Pro, runs the ISO's own
                                               specialize pass (the Zero stack install), then boots to
                                               AUDIT mode and runs zero-golden\\audit.ps1 (checks,
                                               cleans, sysprep /generalize /oobe /shutdown)
    unattend.py shipped ISO_AUTOUNATTEND OUT   handed to sysprep /unattend: the ISO's specialize and
                                               oobeSystem passes unchanged (what every laptop runs on
                                               its first boot), no windowsPE pass

Text surgery on purpose: the specialize/oobeSystem XML stays byte-for-byte what the ISO ships.
"""
import re
import sys
import xml.dom.minidom

COMP = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
# Microsoft's published generic installation key for Windows 11 Pro. It only selects the edition and
# never activates; it keeps Setup in the VM (which has no firmware key) from stopping at the product
# key page. Each laptop's own OEM key comes from its firmware (see firstboot.ps1).
GENERIC_PRO_KEY = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"


def settings_block(text, name):
    m = re.search(r'[ \t]*<settings pass="%s">.*?</settings>[ \t]*\r?\n' % name, text, re.S)
    if not m:
        sys.exit("answer file has no %s pass" % name)
    return m


def run_sync(order, desc, path):
    return ('        <RunSynchronousCommand wcm:action="add">\n'
            '          <Order>%d</Order>\n          <Description>%s</Description>\n          <Path>%s</Path>\n'
            '        </RunSynchronousCommand>\n') % (order, desc, path)


def build(text):
    pe = settings_block(text, "windowsPE")
    intl = re.search(r'[ \t]*<component name="Microsoft-Windows-International-Core-WinPE".*?</component>\r?\n', pe.group(0), re.S)
    labcfg = "".join(run_sync(i + 1, "Setup in a VM: skip the Windows 11 hardware check (" + v + ")",
                              r"reg.exe add HKLM\SYSTEM\Setup\LabConfig /v %s /t REG_DWORD /d 1 /f" % v)
                     for i, v in enumerate(("BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck",
                                            "BypassCPUCheck", "BypassStorageCheck")))
    new_pe = ('  <settings pass="windowsPE">\n' + (intl.group(0) if intl else "") +
              '    <component name="Microsoft-Windows-Setup" %s>\n' % COMP +
              '      <RunSynchronous>\n' + labcfg + '      </RunSynchronous>\n'
              '      <DiskConfiguration>\n'
              '        <Disk wcm:action="add">\n'
              '          <DiskID>0</DiskID>\n'
              '          <WillWipeDisk>true</WillWipeDisk>\n'
              '          <CreatePartitions>\n'
              '            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>\n'
              '            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>\n'
              '            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>\n'
              '          </CreatePartitions>\n'
              '          <ModifyPartitions>\n'
              '            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>\n'
              '            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>\n'
              '          </ModifyPartitions>\n'
              '        </Disk>\n'
              '        <WillShowUI>OnError</WillShowUI>\n'
              '      </DiskConfiguration>\n'
              '      <ImageInstall>\n'
              '        <OSImage>\n'
              '          <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom>\n'
              '          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>\n'
              '          <WillShowUI>OnError</WillShowUI>\n'
              '        </OSImage>\n'
              '      </ImageInstall>\n'
              '      <UserData>\n'
              '        <AcceptEula>true</AcceptEula>\n'
              '        <ProductKey><Key>%s</Key><WillShowUI>Never</WillShowUI></ProductKey>\n' % GENERIC_PRO_KEY +
              '      </UserData>\n'
              '      <DynamicUpdate><Enable>false</Enable><WillShowUI>Never</WillShowUI></DynamicUpdate>\n'
              '    </component>\n'
              '  </settings>\n')
    text = text[:pe.start()] + new_pe + text[pe.end():]
    oobe = settings_block(text, "oobeSystem")
    reseal = ('    <component name="Microsoft-Windows-Deployment" %s>\n' % COMP +
              '      <Reseal><Mode>Audit</Mode></Reseal>\n'
              '    </component>\n')
    body = oobe.group(0)
    body = body.replace("  </settings>", reseal + "  </settings>", 1)
    audit = ('  <settings pass="auditUser">\n'
             '    <component name="Microsoft-Windows-Deployment" %s>\n' % COMP +
             '      <RunSynchronous>\n' +
             run_sync(1, "Zero golden image: check the stack, clean per-machine state, sysprep /generalize /oobe",
                      r'cmd.exe /c "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass '
                      r'-File %WINDIR%\Setup\Scripts\zero-golden\audit.ps1 &gt; %WINDIR%\Setup\Scripts\zero-golden\audit.log 2&gt;&amp;1"') +
             '      </RunSynchronous>\n'
             '    </component>\n'
             '  </settings>\n')
    text = text[:oobe.start()] + body + audit + text[oobe.end():]
    return text


def shipped(text):
    pe = settings_block(text, "windowsPE")
    text = text[:pe.start()] + text[pe.end():]
    note = ("<!--\n  Zero golden image: the answer file sysprep /generalize /oobe left in the image\n"
            "  (golden/windows/unattend.py shipped = the ISO's autounattend.xml without its windowsPE pass).\n"
            "  On each laptop's first boot: specialize (unique SID, PnP with the injected drivers, the Zero\n"
            "  stack re-check + a fresh per-machine llama-server API key), then OOBE (owner creates the account).\n-->\n")
    return re.sub(r"(<unattend )", note + r"\1", text, count=1)


def main():
    mode, src, out = sys.argv[1:4]
    text = open(src, encoding="utf-8-sig").read()
    if "@OEM_MODEL@" in text:
        sys.exit("%s still has the @OEM_MODEL@ placeholder: use the autounattend.xml from the built ISO" % src)
    text = {"build": build, "shipped": shipped}[mode](text)
    xml.dom.minidom.parseString(text.encode("utf-8"))  # well-formed
    with open(out, "w", encoding="utf-8", newline="\r\n") as f:
        f.write(text)
    print("%s answer file -> %s" % (mode, out))


if __name__ == "__main__":
    main()
