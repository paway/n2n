//
//  N2NThread.m
//  n2n
//
//  Created by Reza Jelveh on 6/5/09.
//  Copyright 2009 Protonet.info. All rights reserved.
//

#import "N2NThread.h"
#import "debug.h"

#import "n2n.h"

@implementation N2NThread
@synthesize _id;
@synthesize _network;

- (id)initWithId:(NSString *)theId andNetwork:(NSDictionary*)theNetwork{
    if(self = [super init]) {
        self._id = theId;
        self._network = theNetwork;
    }
    return self;
}

- (void)dealloc {
    self._id = nil;
    self._network = nil;
    [super dealloc];
}

- (void)edgeCleanup:(n2n_edge_t *)eee {
    send_deregister( eee, &(eee->supernode));

    closesocket(eee->udp_sock);
    tuntap_close(&(eee->device));

    edge_deinit( eee );
}

- (void)runLoop:(n2n_edge_t *)eee {
    int   keep_running=1;
    size_t numPurged;
    time_t lastIfaceCheck=0;
    time_t lastTransop=0;

    /* Main loop
     *
     * select() is used to wait for input on either the TAP fd or the UDP/TCP
     * socket. When input is present the data is read and processed by either
     * readFromIPSocket() or readFromTAPSocket()
     */

    while(keep_running)
    {
        int rc, max_sock = 0;
        fd_set socket_mask;
        struct timeval wait_time;
        time_t nowTime;

        FD_ZERO(&socket_mask);
        FD_SET(eee->udp_sock, &socket_mask);
        FD_SET(eee->udp_mgmt_sock, &socket_mask);
        max_sock = max( eee->udp_sock, eee->udp_mgmt_sock );
#ifndef WIN32
        FD_SET(eee->device.fd, &socket_mask);
        max_sock = max( max_sock, eee->device.fd );
#endif

        if([self isCancelled]){
            NSLog(@"N2NThread was cancelled");
            [[NSDistributedNotificationCenter defaultCenter]
                postNotification:[NSNotification notificationWithName:N2N_DISCONNECTING object:_id]];
            break;
        }

        wait_time.tv_sec = SOCKET_TIMEOUT_INTERVAL_SECS; wait_time.tv_usec = 0;

        rc = select(max_sock+1, &socket_mask, NULL, NULL, &wait_time);
        nowTime=time(NULL);

        /* Make sure ciphers are updated before the packet is treated. */
        if ( ( nowTime - lastTransop ) > TRANSOP_TICK_INTERVAL )
        {
            lastTransop = nowTime;

            n2n_tick_transop( eee, nowTime );
        }

        if(rc > 0)
        {
            /* Any or all of the FDs could have input; check them all. */

            if(FD_ISSET(eee->udp_sock, &socket_mask))
            {
                /* Read a cooked socket from the internet socket. Writes on the TAP
                 * socket. */
                readFromIPSocket(eee);
            }

            if(FD_ISSET(eee->udp_mgmt_sock, &socket_mask))
            {
                /* Read a cooked socket from the internet socket. Writes on the TAP
                 * socket. */
                readFromMgmtSocket(eee, &keep_running);
            }

#ifndef WIN32
            if(FD_ISSET(eee->device.fd, &socket_mask))
            {
                /* Read an ethernet frame from the TAP socket. Write on the IP
                 * socket. */
                readFromTAPSocket(eee);
            }
#endif
        }

        /* Finished processing select data. */


        update_supernode_reg(eee, nowTime);

        numPurged =  purge_expired_registrations( &(eee->known_peers) );
        numPurged += purge_expired_registrations( &(eee->pending_peers) );
        if ( numPurged > 0 )
        {
            traceEvent( TRACE_NORMAL, "Peer removed: pending=%u, operational=%u",
                        (unsigned int)peer_list_size( eee->pending_peers ), 
                        (unsigned int)peer_list_size( eee->known_peers ) );
        }

        if ( eee->dyn_ip_mode && 
             (( nowTime - lastIfaceCheck ) > IFACE_UPDATE_INTERVAL ) )
        {
            traceEvent(TRACE_NORMAL, "Re-checking dynamic IP address.");
            tuntap_get_address( &(eee->device) );
            lastIfaceCheck = nowTime;
        }

    } /* while */

    [self edgeCleanup:eee];
    [[NSDistributedNotificationCenter defaultCenter]
        postNotification:[NSNotification notificationWithName:N2N_DISCONNECTED object:_id]];

}

- (void)main
{
    NSLog(@"thread started");
    NSAutoreleasePool	 *autoreleasePool = [[NSAutoreleasePool alloc] init];

    NSString *ipAddress     = [[NSUserDefaults standardUserDefaults] stringForKey:@"ipAddress"];
    NSString *encryptKey    = [_network objectForKey:@"key"];
    NSString *communityName = [_network objectForKey:@"community"];
    NSString *supernodeIp   = [_network objectForKey:@"supernode"];

    int local_port = 0 /* any port */;
    char *tuntap_dev_name = "edge0";
    char  netmask[N2N_NETMASK_STR_SIZE]="255.255.255.0";
    int   mtu = DEFAULT_MTU;
    int   mgmt_port = N2N_EDGE_MGMT_PORT; /* 5644 by default */
    char  ip_mode[N2N_IF_MODE_SIZE]="static";

    char * device_mac=NULL;

    const char *ip_addr        = [ipAddress UTF8String];
    const char *encrypt_key    = [encryptKey UTF8String];
    const char *community_name = [communityName UTF8String];
    const char *supernode_ip   = [supernodeIp UTF8String];

    n2n_edge_t eee; /* single instance for this program */

    [[NSDistributedNotificationCenter defaultCenter]
        postNotification:[NSNotification notificationWithName:N2N_CONNECTING object:_id]];

    if (-1 == edge_init(&eee) ){
        traceEvent( TRACE_ERROR, "Failed in edge_init" );
        return(1);
    }

    memset( eee.community_name, 0, N2N_COMMUNITY_SIZE );
    strncpy( (char *)eee.community_name, community_name, N2N_COMMUNITY_SIZE);

    memset(&(eee.supernode), 0, sizeof(eee.supernode));
    eee.supernode.family = AF_INET;

    eee.sn_num = 0;
    strncpy( (eee.sn_ip_array[0]), supernode_ip, N2N_EDGE_SN_HOST_SIZE);
    supernode2addr(&(eee.supernode), eee.sn_ip_array[0]);

    // -a dhcp:0.0.0.0
    scan_address(ip_addr, N2N_NETMASK_STR_SIZE,
                 ip_mode, N2N_IF_MODE_SIZE,
                 "dhcp:0.0.0.0" );
    eee.dyn_ip_mode = 1;
    // -r
    eee.allow_routing = 1;
    // -E
    eee.drop_multicast=0;

    if(tuntap_open(&(eee.device), tuntap_dev_name, ip_mode, ip_addr, netmask, device_mac, mtu) < 0)
        return(-1);

    if(local_port > 0)
        traceEvent(TRACE_NORMAL, "Binding to local port %d", local_port);

    if ( encrypt_key ) {
        if(edge_init_twofish( &eee, (uint8_t *)(encrypt_key), strlen(encrypt_key) ) < 0) {
            fprintf(stderr, "Error: twofish setup failed.\n" );
            return(-1);
        }
    } else if ( strlen(eee.keyschedule) > 0 ) {
        if (edge_init_keyschedule( &eee ) != 0 ) {
            fprintf(stderr, "Error: keyschedule setup failed.\n" );
            return(-1);
        }

    }
    eee.udp_sock = open_socket(local_port, 1 /*bind ANY*/ );
    if(eee.udp_sock < 0)
    {
        traceEvent( TRACE_ERROR, "Failed to bind main UDP port %u", (signed int)local_port );
        return(-1);
    }

    eee.udp_mgmt_sock = open_socket(mgmt_port, 0 /* bind LOOPBACK*/ );

    if(eee.udp_mgmt_sock < 0)
    {
        traceEvent( TRACE_ERROR, "Failed to bind management UDP port %u", (unsigned int)N2N_EDGE_MGMT_PORT );
        return(-1);
    }


    traceEvent(TRACE_NORMAL, "edge started");

    update_supernode_reg(&eee, time(NULL) );


    update_supernode_reg(&eee, time(NULL) );


    traceEvent(TRACE_NORMAL, "");
    traceEvent(TRACE_NORMAL, "Ready");

    [[NSDistributedNotificationCenter defaultCenter]
        postNotification:[NSNotification notificationWithName:N2N_CONNECTED object:_id]];
    [self runLoop:&eee];

    // autorelease again
    [autoreleasePool release];

}

@end
