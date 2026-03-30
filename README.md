# PI-LEIC

## How to run the simulation

### Option A:

There is a shell scipt that automates the setup, opening all the terminals needed.

```bash
    cd /PI-LEIC/src
    ./launch_stack.sh
```

You will have to enter your password in all terminals since all of them execute with sudo - they need permission.

### Option A:

You can also open the terminals manually:

- 1st: On the first terminal, open the core logs:

```bash
    sudo tail -f /var/log/open5gs/amf.log
```

- 2nd: On the second terminal, start the gNB:

```bash
    cd config && sudo gnb -c gnb_zmq.yaml
```

- 3rd: On the third terminal, start the UE:

```bash
    cd config && sudo srsue ue_zmq.conf.txt
```

To test the connection, you may want to ping. For that purpose, create a new network interface:

```bash
    sudo ip netns del ue1 2>/dev/null
    sudo ip netns add ue1
```

```bash
    sudo ip netns exec ue1 ping 10.45.0.1
```

You now should have the setup complete. However, you might want to collect metrics:

- Open another terminal and run the script:

```bash
    cd src && python3 metrics_exporter.py
```

If you want to visualize the the real-time dashboard, open another terminal and run the script:

```bash
    cd src && python3 dashboard.py
```


## Other useful information / commands

```bash
    sudo systemctl restart open5gs-amfd open5gs-smfd open5gs-upfd   //restart core
```

You may want to access webui to register another UE:

Username: admin<br>
Password: 1423

```bash
    sudo systemctl enable open5gs-webui
    sudo systemctl start open5gs-webui
```
