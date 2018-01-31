# Install Guide for Salt + NAPALM for Junos!

This guide will take you from a new virtual machine (or two) based on Ubuntu Server 16.04 to a working Salt installation with NAPALM-logs and a proxy minion.

In terms of a system architecture, the basic components are below. In this walkthrough, all components live on a single server, but in production systems it's quite normal for each of these components to be on separate servers.

```bash
     +-----------------------------------------+
     |                                         |
     |  +----------------------------------+   |
     |  |            Salt-Master           |   |
     |  |         (salt+master +d)         |   |
     |  +----------------------------------+   |
     |                  |zmq|                  |
     |  +----------------------------------+   |
     |  |           Salt-Minion            |   |
     |  |         (salt-minion -d)         |   |
     |  |       napalm-logs engine        ---------|
     |  +----------------------------------+   |   |
     |                  |zmq|                  |   |
     |  +----------------------------------+   |   |
     |  |             Salt-Proxy           |   |   |
     |  | (salt-proxy --proxyid=<id> -d)   |   |   |
     |  +----------------------------------+   |   |
     |                                         |   |
     |  +----------------------------------+   |   |
     |  |            napalm-logs           --------|
     |  |       pub: zmq  port: 5678       |   |   
     |  +----------------------------------+   |
     |                                         |
     |               UBUNTU 16.04              |
     |                                         |
     +-----------------------------------------+

```

As we start the walk through, let's make sure our new virtual machine is up to date.

1.  Update and upgrade
```bash
sudo apt-get update && sudo apt-get upgrade
```

2.  Install requirements for NAPALM
```bash
sudo apt-get install libffi-dev libssl-dev python-dev python-cffi libxslt1-dev python-pip
sudo pip install --upgrade cffi
sudo pip install napalm-junos
```

3.  Install the Salt packages

Following the information here, add the SaltStack repository key to your system and also add the saltstack source to apt (assuming running on a Debian/Ubuntu system, if not, update as per your operating system): [Salt info](https://repo.saltstack.com/#ubuntu)

```bash
wget -O - https://repo.saltstack.com/apt/ubuntu/16.04/amd64/latest/SALTSTACK-GPG-KEY.pub | sudo apt-key add -
deb http://repo.saltstack.com/apt/ubuntu/16.04/amd64/latest xenial main

apt-get install salt-master
apt-get install salt-minion
```

4.  Configure a Salt master and Minion.

Create a master configuration file. This contains the file_roots location, pillar_roots and fileserver_backend. The reactor section is how we handle events and I've pre-populated it with two different reactions, which will be explained later.

Master file:

```bash
# root@saltmaster:~# cat /etc/salt/master
file_roots:
  base:
    - /srv/salt

pillar_roots:
  base:
    - /srv/pillar

fileserver_backend:
  - roots

reactor:
  - 'napalm/syslog/junos/CONFIGURATION_COMMIT_REQUESTED/*':
    - /srv/reactor/get_version.sls


# root@saltmaster:~# cat /srv/reactor/get_version.sls
get_version:
  local.net.cli:
    - tgt: vsrxnapalm
    - arg:
      - "show version"
```

This guide does not cover the reactor system, tags or events. This is a basic setup guide. There is much to learn here and the basic idea is that each event essentially is a tag like `'napalm/syslog/junos/CONFIGURATION_COMMIT_REQUESTED/*'` which can be matched upon. The direct list of items below is executed when a match occurs.

Create the minion configuration file. This file contains the all important pointer back to the master and this particular minion will run the reactor engine 'napalm_syslog'. Running the engines on minions will move some load off the master. Note here, the `engine`, which is a Salt module that will communicate to the napalm-logs engine.

```bash
# vagrant@minion1:~/eventdata$ cat /etc/salt/minion
master: localhost
id: minion1
engines:
  - napalm_syslog:
      transport: zmq
      address: localhost
      port: 5678
      disable_security: true
```

Also, on the minion (where our napalm log collector will be), we also need to create the configuration file for `napalm-logs`. A directory will also need to be created.

```bash
mkdir /etc/napalm

#vagrant@minion1:~/eventdata$ cat /etc/napalm/logs
transport: zmq
log_level: info
port: 514
disable_security: true
publish_port: 5678
publish_address: 0.0.0.0
```

At this point we've got most of the configuration in place required to bootstrap our Salt system. The more alert of you will realise that we haven't yet installed the NAPALM packages yet! Let's install our dependencies:

```bash
pip install napalm napalm-base napalm-junos napalm-logs
```

__WARNING__: At this point, your Python package manager might be broken. If you see warnings ending with patterns like below, do not fear. It's fixed relatively easily.

```bash
<snip/>File "/usr/lib/python2.7/dist-packages/OpenSSL/SSL.py", line 118, in <module>
  SSL_ST_INIT = _lib.SSL_ST_INIT
AttributeError: 'module' object has no attribute 'SSL_ST_INIT'
```

To fix:

```bash
sudo python -m easy_install --upgrade pyOpenSSL
```

## Start Sevices

*At this point, it will prove wise to open multiple terminal sessions. I use a terminal multiplexer application called `tmux` to allow me to open multiple terminal sessions in the same window and move around them.*

Just to make sure that things are going to work properly, I always start the salt components in the foreground with the debug level. This helps me to avoid silly issues further down the line.

```bash
sudo salt-master -l debug
```

Once you're happy no errors are present (it will not only exit(code > 0) but the error message will be clearly displayed) then you can stop the master with `ctrl+c`.


Now start the `salt-master` as a daemon (which will run as a service in the background).

```bash
sudo salt-master -d
```

*On Ubuntu it's also possible to use `sudo service salt-master start|stop|status|restart|force-reload`*

Now let's run the salt-minion in foreground with the log level set to debug:

```bash
sudo salt-minion -l debug
```

If this is the first time you've ran the salt-minion, you will see a log message regarding keys.

Salt minons and proxy-minions communicate over a message bus and they do this using private and public keys. Therefore, when starting a new minion or proxy-minion, be sure to accept the keys.

You can view the known keys on the master and accept all pending or individual keys:

```bash
sudo salt-keys -L # Show keys
sudo salt-keys -a minion1 # Accept minion1 key
sudo salt-keys -A # Accept all pending keys
sudo salt-keys -d minion1 # Delete a single key
sudo salt-keys -D # Delete all keys
```

Once you're happy no errors are present (it will not only exit(code > 0) but the error message will be clearly displayed) then you can stop the master with `ctrl+c`. Once the foreground application has exited, be sure to start the salt-minion as a daemonised process.

```bash
sudo salt-minion -d
```
*On Ubuntu it's also possible to use `sudo service salt-minion start|stop|status|restart|force-reload`*

At this point, we can now issue a test.ping to all nodes. Our minion should respond!

```bash
sudo salt '*' test.ping
# Returns >
# minion1:
#    True
```

## Salt NAPALM Proxy Minion

As this is a NAPALM focussed 'how-to', we also need to do two more things:

a)  Configure and start a NAPALM proxy for a Junos node (in my case, a vSRX device)
b)  Start the `NAPALM-logs` application and ensure it's communicating with the Salt NAPALM-log engine

__NAPALM proxy-minion__

Many networking devices do not allow us to run Linux packages for fear of crashing mission critical infrastructure. With technology like NSF (Non-Stop Forwarding) which allows devices to carry on forwarding packets if the control-plane crashes, it's less of a worry, but never-the-less, let us take the high road. Junos requires that we use something called a proxy-minion instead of loading minion software packages on to Junos. This proxy-minion service lives on another node, like the master or a minion, but in turn, it communicates over *some* transport to a node that requires communication via proxy, like a network node. Proxies and this manner of communication is common for other automation platforms like Ansible, Puppet and StackStorm. The napalm-proxy has a number of built in drivers, including Junos, which uses NETCONF as its transport.

We do not configure a proxy-minion with Salt like other minions; we do it via Pillar data, which is then referred to when running a proxy. Pillar data is static data that we can push out from the master to minions to be used in Salt state and function executions.

Our system as of this moment (unless you've done something) lacks pillar data.

```bash
sudo salt '*' pillar.items
# Returns >
# minion1:
#     ----------
```

Let's configure Pillar data to allow us to start a `proxy-minion` which will use NAPALM to communicate with Junos!

We will also need a proxy configuration file which points back to the master.

```bash
#cat /etc/salt/proxy
master: localhost
multiprocessing: false
mine_enabled: true
```
*These settings for the proxy do not allow multi-processing to happen and the salt-mine is enabled.*

For the pillar data, we also need to create a directory to house the data.

```bash
mkdir /srv/pillar

#cat /srv/pillar/top.sls
base:
  '*':
    - default
  'vsrxnapalm':
    - vsrx01_napalm

#cat /srv/pillar/vsrx01_napalm.sls
proxy:
  proxytype: napalm
  driver: junos
  host: 192.168.10.150
  username: salt
  passwd: Passw0rd
```

The `top.sls` Pillar file links to the `vsrx01_napalm.sls` file. Note how the `top.sls` file leaves off the .sls file extension. I'll also point out here that every node is targeted to contain the 'default.sls' pillar items. From fresh, your system will not have that pillar. Feel free to remove it.

Now we have this information in place, let's start a proxy-minion and accept it's key on the master.

```bash
sudo salt-proxy --proxyid=vsrxnapalm -l debug
```

As per usual, let's accept the key on the master from the proxy-minion.

```bash
salt-key -L
#Accepted Keys:
#minion1
#Denied Keys:
#Unaccepted Keys:
#vsrxnapalm
#Rejected Keys:

salt-key -a vsrxnapalm
```

Now, just to make sure the proxy works, let's run in debug mode once again.

```bash
sudo salt-proxy --proxyid=vsrxnapalm -l debug
```

If you do not see an error that makes the proxy crash and a huge amount of information from NETCONF calls, then you're good to do. Issue `ctrl+c` to the foreground process and daemonise it with the following:

```bash
sudo salt-proxy --proxyid=vsrxnapalm -d
```

Once this is working, we can repeat some steps taken earlier to prove that the proxy-minion can connect to the vsrx device.

```bash
sudo salt '*' test.ping
# Returns
#minion1:
#    True
#vsrxnapalm:
#    True
```
Great, we have our minion and proxy-minion responding. This does so much more than respond and the proxy-minion responds success only if it can connect to the network node we're proxying access to for Salt!

## NAPALM-Logs

Now we have a basic system running with a Salt master, minion and proxy, we're good to move to the next phase which is reacting to logs from Junos.

For this, let's view events on the bus. This will help us see a Syslog enter the system through napalm-logs and the Salt engine will collect that data and place it on to the Salt event bus.

```bash
sudo salt-run state.event pretty=True
```

We can also verify connectivity between the Salt napalm-logs engine and the napalm-logs application by observing socket states:

```bash
netstat -aln | grep -E "514|5678"
#tcp        0      0 0.0.0.0:5678            0.0.0.0:*               LISTEN
#tcp        0      0 127.0.0.1:5678          127.0.0.1:33970         ESTABLISHED
#tcp        0      0 127.0.0.1:33970         127.0.0.1:5678          ESTABLISHED
#udp        0      0 0.0.0.0:514             0.0.0.0:*
```

So far so good. The syslog standard port is open to receive syslogs and we have connectivity over port 5678 for the napalm-logs transport.

Now we need to configure our vsrx to send syslog content to the napalm-logs application on port 514. Replace IP information with your own.

```bash
# Submit these commands to your Junos device
set system syslog host 192.168.50.11 any any
set system syslog host 192.168.50.11 port 514
set system syslog host 192.168.50.11 source-address 192.168.50.13
commit
```

Now, we need to trigger a change to observe if our system is indeed functioning!

```bash
set interfaces ge-0/0/0.0 description "Modified description"
```

If we observe the terminal that is observing the event bus, you can expect to see messages like below, confirming the system is working as expected.
When our event tag was matched through the reactor system, the reactor task was also executed, which in this case was a fairly useless example; we ran a CLI command! However, as useless as it might be, we can see the results clearly on the event bus.

```bash
napalm/syslog/junos/CONFIGURATION_COMMIT_REQUESTED/vsrx01	{
    "_stamp": "2018-01-31T22:20:38.982475",
    "cmd": "_minion_event",
    "data": {
        "error": "CONFIGURATION_COMMIT_REQUESTED",
        "facility": 23,
        "host": "vsrx01",
        "ip": "192.168.50.1",
        "message_details": {
            "date": "Jan 31",
            "facility": 23,
            "host": "vsrx01",
            "hostPrefix": null,
            "message": "User 'root' requested 'commit' operation (comment: none)",
            "pri": "189",
            "processId": "2780",
            "processName": "mgd",
            "severity": 5,
            "tag": "UI_COMMIT",
            "time": "19:11:59"
        },
        "os": "junos",
        "severity": 5,
        "timestamp": 1517425919,
        "yang_message": {
            "users": {
                "user": {
                    "root": {
                        "action": {
                            "comment": "none",
                            "requested_commit": true
                        }
                    }
                }
            }
        },
        "yang_model": "NO_MODEL"
    },
    "id": "minion1",
    "pretag": null,
    "tag": "napalm/syslog/junos/CONFIGURATION_COMMIT_REQUESTED/vsrx01"
}
20180131222038991138	{
    "_stamp": "2018-01-31T22:20:38.991360",
    "minions": [
        "vsrxnapalm"
    ]
}
salt/job/20180131222038991138/new	{
    "_stamp": "2018-01-31T22:20:38.991789",
    "arg": [
        "show version"
    ],
    "fun": "net.cli",
    "jid": "20180131222038991138",
    "minions": [
        "vsrxnapalm"
    ],
    "tgt": "vsrxnapalm",
    "tgt_type": "glob",
    "user": "root"
}
salt/job/20180131222038991138/ret/vsrxnapalm	{
    "_stamp": "2018-01-31T22:20:39.179521",
    "cmd": "_return",
    "fun": "net.cli",
    "fun_args": [
        "show version"
    ],
    "id": "vsrxnapalm",
    "jid": "20180131222038991138",
    "retcode": 0,
    "return": {
        "comment": "",
        "out": {
            "show version": "\nHostname: vsrx01\nModel: firefly-perimeter\nJUNOS Software Release [12.1X47-D15.4]\n"
        },
        "result": true
    },
    "success": true
}
```

### Exit(0)

Hopefully this guide and associated files proved to be useful. Any errata or corrections, please feel free to issue a PR against this repo.
