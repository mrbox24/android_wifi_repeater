# android_wifi_repeater
This is my updated version of the script found here...

https://android.stackexchange.com/questions/37141/how-to-use-android-in-wi-fi-repeater-mode-by-bridging-wi-fi-with-access-point

The Debian Chroot Version
Debian's iptables may hang on some devices with this script, to fix this I replace Debian's iptables with Android's, placing Android iptables in my ~/.bin

I use Debian's hostapd and dnsmasq.

Tested on Android 8.1 and 9 both both running Lineage/AOSP based roms. 
