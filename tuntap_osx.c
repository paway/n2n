/*
 * (C) 2007-09 - Luca Deri <deri@ntop.org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not see see <http://www.gnu.org/licenses/>
 */

#include "n2n.h"

#ifdef _DARWIN_

void tun_close(tuntap_dev *device);

#ifdef BUILD_FRONTEND
#include <sys/socket.h>
#include <sys/un.h>

#define QLEN 10

#define ADDRESS "/tmp/somesocketstuffs"

int sock_server(){
    int len;
    int fd;
    struct sockaddr_un saun;

    if((fd = socket(PF_LOCAL, SOCK_STREAM, 0)) < 0){
        perror("server: socket");
        return -1;
    }

    saun.sun_family = PF_LOCAL;
    strcpy(saun.sun_path, ADDRESS);

    unlink(saun.sun_path);
    len = sizeof(saun.sun_family) + strlen(saun.sun_path);

    if (bind(fd, &saun, len) < 0) {
        perror("server: bind");
        return -2;
    }

    if (listen(fd, QLEN) < 0) { /* tell kernel we're a server */
        perror("server: listen");
        return -3;
    }

    return 0;
}
#endif

/* ********************************** */

#define N2N_OSX_TAPDEVICE_SIZE 32
int tuntap_open(tuntap_dev *device /* ignored */, 
                char *dev, 
                char *device_ip, 
                char *device_mask,
                const char * device_mac,
		int mtu) {
  int i;
  char tap_device[N2N_OSX_TAPDEVICE_SIZE];

#ifndef BUILD_FRONTEND
  for (i = 0; i < 255; i++) {
    snprintf(tap_device, sizeof(tap_device), "/dev/tap%d", i);

    device->fd = open(tap_device, O_RDWR);
    if(device->fd > 0) {
      traceEvent(TRACE_NORMAL, "Succesfully open %s", tap_device);
      break;
    }
  }
#else
  sock_server();

  execl("/Users/timebomb/Library/Application Support/ganesh/n2n.app/Contents/Resources/TunHelper", (char*)0);
#endif

  if(device->fd < 0) {
    traceEvent(TRACE_ERROR, "Unable to open tap device");
    return(-1);
  } else {
    char buf[256];
    FILE *fd;

    device->ip_addr = inet_addr(device_ip);

    if ( device_mac )
    {
        /* FIXME - This is not tested. Might be wrong syntax for OS X */

        /* Set the hw address before bringing the if up. */
        snprintf(buf, sizeof(buf), "ifconfig tap%d ether %s",
                 i, device_mac);
        system(buf);
    }

    snprintf(buf, sizeof(buf), "ifconfig tap%d %s netmask %s mtu %d up",
             i, device_ip, device_mask, mtu);
    system(buf);

    traceEvent(TRACE_NORMAL, "Interface tap%d up and running (%s/%s)",
               i, device_ip, device_mask);

  /* Read MAC address */

    snprintf(buf, sizeof(buf), "ifconfig tap%d |grep ether|cut -c 8-24", i);
    /* traceEvent(TRACE_INFO, "%s", buf); */

    fd = popen(buf, "r");
    if(fd < 0) {
      tun_close(device);
      return(-1);
    } else {
      int a, b, c, d, e, f;

      buf[0] = 0;
      fgets(buf, sizeof(buf), fd);
      pclose(fd);
      
      if(buf[0] == '\0') {
	traceEvent(TRACE_ERROR, "Unable to read tap%d interface MAC address");
	exit(0);
      }

      traceEvent(TRACE_NORMAL, "Interface tap%d [MTU %d] mac %s", i, mtu, buf);
      if(sscanf(buf, "%02x:%02x:%02x:%02x:%02x:%02x", &a, &b, &c, &d, &e, &f) == 6) {
	device->mac_addr[0] = a, device->mac_addr[1] = b;
	device->mac_addr[2] = c, device->mac_addr[3] = d;
	device->mac_addr[4] = e, device->mac_addr[5] = f;
      }
    }
  }


  /* read_mac(dev, device->mac_addr); */
  return(device->fd);
}

/* ********************************** */

int tuntap_read(struct tuntap_dev *tuntap, unsigned char *buf, int len) {
  return(read(tuntap->fd, buf, len));
}

/* ********************************** */

int tuntap_write(struct tuntap_dev *tuntap, unsigned char *buf, int len) {
  return(write(tuntap->fd, buf, len));
}

/* ********************************** */

void tuntap_close(struct tuntap_dev *tuntap) {
  close(tuntap->fd);
}

#endif
