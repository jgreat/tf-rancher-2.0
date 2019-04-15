import json
import boto3
import botocore
import logging
import os
import paramiko
import socket
import subprocess
import warnings
import yaml

from random import randint
from time import sleep
from paramiko.ssh_exception import BadHostKeyException, AuthenticationException, SSHException

warnings.filterwarnings(action='ignore',module='.*paramiko.*')

print('Loading function')

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    sleep(randint(1,15))

    base_cluster_path = '/tmp/base_cluster.yml'
    cluster_path = '/tmp/cluster.yml'
    json_vars_path = '/tmp/vars.json'
    kubeconfig_path = '/tmp/kube_config_cluster.yml'
    snapshot_path = '/tmp/snapshots'
    s3_bucket = os.environ['S3_BUCKET']
    rke_version = os.environ['RKE_VERSION']
    ssh_user = os.environ.get('SSH_USER', default='rancher')
    rke_path = '/tmp/rke'
    state_path = '/tmp/cluster.rkestate'
    ssh_key_path = '/tmp/rsa_id'

    logger.info(json.dumps(event, indent=4, sort_keys=True))

    message = json.loads(event['Records'][0]['Sns']['Message'])

    if 'LifecycleTransition' not in message:
        logger.info('Not a autoscale transition event. Doing nothing.')
        return

    transition = message['LifecycleTransition']
    lifecycle_action_token = message['LifecycleActionToken']
    metadata = json.loads(message['NotificationMetadata'])
    lb = metadata['lb']

    ec2 = boto3.resource('ec2')
    instance = ec2.Instance(message['EC2InstanceId'])
    if instance.public_ip_address:
        ip = instance.public_ip_address
        internal_ip = instance.private_ip_address
    else:
        ip = instance.private_ip_address
        internal_ip = ""
    logger.info(message)
    logger.info('Instance ID: {}'.format(message['EC2InstanceId']))
    logger.info('Transition: {}'.format(transition))
    logger.info('Address: {}'.format(ip))
    logger.info('Internal Address: {}'.format(internal_ip))
    logger.info('LB Endpoint: {}'.format(lb))

    try:
        # Get instance info
        logger.info('Waiting for instance to be ready')
        instance.wait_until_running()
        logger.info('Instance is in Running state')

        # Download RKE
        get_rke(version=rke_version, path=rke_path)

        # Get SSH key
        get_ssh_private_key(bucket=s3_bucket, path=ssh_key_path)

        # Test docker ready
        wait_for_docker(private_key_path=ssh_key_path, ip=ip)

        # Set Lock
        set_lock(bucket=s3_bucket, ip=ip)

        # Get state files
        get_kubeconfig(bucket=s3_bucket, path=kubeconfig_path)
        get_state(bucket=s3_bucket, path=state_path)
        get_base_cluster(bucket=s3_bucket, path=base_cluster_path)
        get_cluster(bucket=s3_bucket, path=cluster_path)

        # Take a snapshot if the cluster exists.
        if os.path.isfile(kubeconfig_path):
            snapshot_name = 'asg-{}-{}'.format(message['LifecycleHookName'],  message['RequestId'])
            local_snapshot_path = '{}/{}'.format(snapshot_path, snapshot_name)
            remote_snapshot_path = '/opt/rke/etcd-snapshots/{}'.format(snapshot_name)

            take_snapshot(name=snapshot_name, rke_path=rke_path, cluster_path=cluster_path)
            if not os.path.isdir(snapshot_path):
                os.mkdir(snapshot_path)
            copy_snapshot(cluster_path=cluster_path, local_path=local_snapshot_path, remote_path=remote_snapshot_path)
            upload_snapshot(bucket=s3_bucket, name=snapshot_name, path=local_snapshot_path)

        # update cluster.yml
        node = {
            'address': ip,
            'internal_address': internal_ip,
            'user': ssh_user,
            'role': [ 'controlplane', 'etcd', 'worker' ],
            'ssh_key_path': ssh_key_path
        }
        if transition == 'autoscaling:EC2_INSTANCE_LAUNCHING':
            add_node(base_cluster_path=base_cluster_path, cluster_path=cluster_path, node=node)
        elif transition == 'autoscaling:EC2_INSTANCE_TERMINATING':
            remove_node(path=cluster_path, node=node)
        else:
            raise Exception('Unknown transition, run away!')

        # run rke
        cmd = [ rke_path, 'up', '--config', cluster_path, '2>&1' ]
        response = subprocess.run(cmd)
        response.check_returncode()

        # Add ELB endpoint to kube_config_cluster.yml
        add_lb_to_kubeconfig(path=kubeconfig_path, lb=lb)

        json_vars_file(kubeconfig_path=kubeconfig_path, json_vars_path=json_vars_path)

        # Update files
        upload_files(bucket=s3_bucket, cluster_path=cluster_path, kubeconfig_path=kubeconfig_path, state_path=state_path, json_vars_path=json_vars_path)

        # Remove lock
        remove_lock(bucket=s3_bucket, ip=ip)

        # Send ASG complete
        complete_lifecycle(message, 'CONTINUE')

    except Exception as e:
        if lifecycle_action_token:
            complete_lifecycle(message, 'ABANDON')
        if ip:
            remove_lock(bucket=s3_bucket, ip=ip)
        raise e
    else:
        logger.info('rke up Success')


def add_lb_to_kubeconfig(path, lb):
    logger.info('Updating Kubeconfig with LB endpoint: {}'.format(lb))
    kube_config = {}
    with open(path, 'r') as k:
        kube_config = yaml.safe_load(k.read())
    kube_config['clusters'][0]['cluster']['server'] = lb
    with open(path, 'w') as k:
        k.writelines(yaml.dump(kube_config, default_flow_style=False))


def json_vars_file(kubeconfig_path, json_vars_path):
    logger.info('Creating json_vars for TF to ingest')
    kube_config = {}
    with open(kubeconfig_path, 'r') as k:
        kube_config = yaml.safe_load(k.read())
    json_vars = {
        'host': kube_config['clusters'][0]['cluster']['server'],
        'username': kube_config['users'][0]['name'],
        'client_certificate_data': kube_config['users'][0]['user']['client-certificate-data'],
        'client_key_data': kube_config['users'][0]['user']['client-key-data'],
        'certificate_authority_data': kube_config['clusters'][0]['cluster']['certificate-authority-data']
    }
    with open(json_vars_path, 'w') as j:
        j.writelines(json.dumps(json_vars))


def take_snapshot(name, rke_path, cluster_path):
    logger.info('Taking snapshot of current cluster. ' + name)
    cmd = [ rke_path, 'etcd', 'snapshot-save', '--config', cluster_path, '--name', name ]
    response = subprocess.run(cmd)
    response.check_returncode()


def copy_snapshot(cluster_path, local_path, remote_path):
    # Pull snapshot from the first host in the cluster.yml
    cluster = {}
    with open(cluster_path, 'r') as c:
        cluster = yaml.safe_load(c.read())

    ip = cluster['nodes'][0]['address']
    user = cluster['nodes'][0]['user']
    ssh_key_path = cluster['nodes'][0]['ssh_key_path']

    logger.info('Copy snapshot from {} to localhost'.format(ip))
    logger.info('Remote path: {}'.format(remote_path))
    logger.info('Local local: {}'.format(local_path))
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    private_key = paramiko.RSAKey.from_private_key_file(ssh_key_path)
    ssh.connect(hostname=ip, username=user, pkey=private_key)

    ftp_client=ssh.open_sftp()
    ftp_client.get(remote_path, local_path)
    ftp_client.close()


def upload_snapshot(bucket, name, path):
    # upload to s3:// /snapshots
    logger.info('Uploading snapshot: ' + path) 
    with open(path, 'rb') as k:
        s3 = boto3.client('s3')
        s3.upload_fileobj(k, bucket, 'snapshots/{}'.format(name), ExtraArgs={'ContentType': 'text/yaml'})


def get_state(bucket, path):
    s3 = boto3.client('s3')
    logger.info('Downloading cluster.rkestate from ' + bucket)
    try:
        s3.download_file(bucket, 'cluster.rkestate', path)
    except botocore.exceptions.ClientError as e:
        if e.response['Error']['Code'] == "404":
            logger.info('no existing state file')
        else:
            raise e


def get_kubeconfig(bucket, path):
    s3 = boto3.client('s3')
    logger.info('Downloading kube_config_cluster.yml from ' + bucket)
    try:
        s3.download_file(bucket, 'kube_config_cluster.yml', path)
    except botocore.exceptions.ClientError as e:
        if e.response['Error']['Code'] == "404":
            logger.info('no existing kubeconfig file')
        else:
            raise e


def get_cluster(bucket, path):
    s3 = boto3.client('s3')
    logger.info('Downloading cluster.yml from ' + bucket)
    try:
        s3.download_file(bucket, 'cluster.yml', path)
    except botocore.exceptions.ClientError as e:
        if e.response['Error']['Code'] == "404":
            logger.info('cluster.yml not found creating new')
            open(path, 'a').close()
        else:
            raise e


def get_base_cluster(bucket, path):
    s3 = boto3.client('s3')
    logger.info('Downloading base_cluster.yml from ' + bucket)
    try:
        s3.download_file(bucket, 'base_cluster.yml', path)
    except botocore.exceptions.ClientError as e:
        if e.response['Error']['Code'] == "404":
            logger.info('base_cluster.yml not found creating new')
            open(path, 'a').close()
        else:
            raise e


def add_node(cluster_path, base_cluster_path, node):
    cluster = {}
    base_cluster = {}
    with open(cluster_path, 'r') as c:
        cluster = yaml.safe_load(c.read())
    # This seems dumb, but an empty document doesn't return an empty dict
    if not cluster:
        cluster = {}
    with open(base_cluster_path, 'r') as c:
        base_cluster = yaml.safe_load(c.read())
    if not base_cluster:
        base_cluster = {}

    # merge base_cluster over values in cluster
    new_cluster = {**cluster, **base_cluster}
    # update cluster with new node
    if new_cluster:
        if 'nodes' in new_cluster:
            if node in new_cluster['nodes']:
                logger.info('found node entry in cluster.yml')
            else:
                logger.info('appending node entry to cluster.yml')
                new_cluster['nodes'].append(node)
        else:
            logger.info('adding node entry to cluster.yml')
            new_cluster['nodes'] = [ node ]
    else:
        logger.info('adding nodes entry to cluster.yml')
        new_cluster = {
            'nodes': [
                node
            ]
        }
    with open(cluster_path, 'w') as c:
        c.writelines(yaml.dump(new_cluster, default_flow_style=False))


def remove_node(path, node):
    cluster = {}
    with open(path, 'r') as c:
        cluster = yaml.safe_load(c.read())
        if cluster:
            if 'nodes' in cluster:
                if node in cluster['nodes']:
                    cluster['nodes'].remove(node)
    with open(path, 'w') as c:
        c.writelines(yaml.dump(cluster, default_flow_style=False))


def upload_files(bucket, cluster_path, kubeconfig_path, state_path, json_vars_path):
    s3 = boto3.client('s3')
    if os.path.isfile(cluster_path):
        logger.info('Uploading cluster.yml') 
        with open(cluster_path, 'rb') as c:
            s3.upload_fileobj(c, bucket, 'cluster.yml', ExtraArgs={'ContentType': 'text/yaml'})
    if os.path.isfile(kubeconfig_path):
        logger.info('Uploading kube_config_path.yml') 
        with open(kubeconfig_path, 'rb') as k:
            s3.upload_fileobj(k, bucket, 'kube_config_cluster.yml', ExtraArgs={'ContentType': 'text/yaml'})
    if os.path.isfile(state_path):
        logger.info('Uploading cluster.rkestate') 
        with open(state_path, 'rb') as s:
            s3.upload_fileobj(s, bucket, 'cluster.rkestate')
    if os.path.isfile(json_vars_path):
        logger.info('Uploading vars.json') 
        with open(json_vars_path, 'rb') as j:
            s3.upload_fileobj(j, bucket, 'vars.json', ExtraArgs={'ContentType': 'application/json'})


def set_lock(bucket, ip):
    s3 = boto3.client('s3')
    logger.info('Checking for lock file')
    # retry every 10 seconds, stop after 10 min
    for attempt in range(60):
        try:
            s3.head_object(Bucket=bucket, Key='rke_lock')
        except botocore.exceptions.ClientError as e:
            if e.response['Error']['Code'] == "404":
                logger.info("The lock_file does not exist. Setting now.")
                with open('/tmp/rke_lock', 'w') as lock:
                    lock.write(ip)
                with open('/tmp/rke_lock', 'rb') as lock:
                    s3.upload_fileobj(lock, bucket, 'rke_lock')
                break
            else:
                raise e
        else:
            logger.info('Lock file exists. Waiting for lock to clear - ' + str(attempt))
            sleep(10)
            continue
    else:
        url = 's3://' + bucket + '/rke_tmp'
        raise Exception('Time out waiting for lock to clear. ' + url)


def remove_lock(bucket, ip):
    s3 = boto3.client('s3')
    logger.info('Removing Lock File')
    try:
        s3.download_file(bucket, 'rke_lock', '/tmp/tmp_lock')
        with open('/tmp/tmp_lock') as t:
            if t.read() == ip:
                s3.delete_object(Bucket=bucket, Key='rke_lock')
            else:
                logger.info('Not my lock file')
    except botocore.exceptions.ClientError as e:
        if e.response['Error']['Code'] == "404":
            logger.info('lock file is gone?')
        else:
            raise e


def get_rke(version, path):
    logger.info('Downloading RKE version ' + version)
    url = 'https://github.com/rancher/rke/releases/download/' + version + '/rke_linux-amd64'
    cmd = [ 'curl', '-fLSs', '-o', path, url ]
    
    subprocess.check_call(cmd)
    subprocess.check_call(['chmod', '+x', path])


def get_ssh_private_key(bucket, path):
    s3 = boto3.client('s3')
    logger.info('Downloading private key from ' + bucket)
    s3.download_file(bucket, 'id_rsa', path)


def wait_for_docker(private_key_path, ip):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    private_key = paramiko.RSAKey.from_private_key_file(private_key_path)

    logger.info('Waiting for Docker to be ready')
    # retry every 10 seconds, stop after 5 min
    for attempt in range(30):
        try:
            ssh.connect(hostname=ip, username='rancher', pkey=private_key)
            stdin, stdout, stderr = ssh.exec_command('docker ps')
            stdin.flush()
            data = stdout.read().splitlines()
            logger.debug(data)
            logger.debug('Return: ' + str(stdout.channel.recv_exit_status()))
            if stdout.channel.recv_exit_status() > 0:
                raise SSHException('Command Failed')
            logger.info('Docker ready')
            ssh.close()
        except (BadHostKeyException, AuthenticationException) as e:
            raise e
        except (SSHException, socket.error) as e:
            ssh.close()
            logger.info('Docker not ready ' + str(attempt))
            sleep(10)
            continue
        else:
            break
    else:
        raise Exception('Wait for docker timed out')

def complete_lifecycle(message, result):
    client = boto3.client('autoscaling')
    client.complete_lifecycle_action(
        LifecycleHookName=message['LifecycleHookName'],
        AutoScalingGroupName=message['AutoScalingGroupName'],
        LifecycleActionToken=message['LifecycleActionToken'],
        LifecycleActionResult=result
    )