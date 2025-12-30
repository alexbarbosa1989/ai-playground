## Enabling Hardware Profile for NVIDIA GPUs
Once the [GPUs are enabled correctly in the OpenShift cluster](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.25/html/working_with_accelerators/enabling-nvidia-gpus_accelerators), the next step is configure the Hardware Profile in the RHOAI(it is hidden by default in RHOAI 2.x)

**Important:** Below example is configured in a SNO Openshift cluster. The GPU was enabled following the [How to enable NVIDIA GPU acceleration in OpenShift Local](https://developers.redhat.com/articles/2025/11/27/how-enable-nvidia-gpu-acceleration-openshift-local#) article procedure

### Basic check for NVIDIA Operator deployments status
When checking the pod's status:
~~~
oc get pods -n nvidia-gpu-operator
~~~
The output should show  `Running`/`Completed` status:
~~~
NAME                                           READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-b2dlm                    1/1     Running     0          7m23s
gpu-operator-7f9f954657-h8578                  1/1     Running     4          6d1h
nvidia-container-toolkit-daemonset-xvn8v       1/1     Running     0          7m23s
nvidia-cuda-validator-j27ch                    0/1     Completed   0          5m53s
nvidia-dcgm-exporter-lthw9                     1/1     Running     0          7m23s
nvidia-dcgm-xrkqf                              1/1     Running     0          7m23s
nvidia-device-plugin-daemonset-bt578           1/1     Running     0          7m23s
nvidia-driver-daemonset-9.6.20250805-0-9wptj   2/2     Running     13         6d1h
nvidia-node-status-exporter-g596h              1/1     Running     4          6d1h
nvidia-operator-validator-wb8f5                1/1     Running     0          7m23s
~~~

### Enable the Hardware Profile in the OdhDashboardConfig CustomResource (CR):
Patch the `OdhDashboardConfig` setting `disableHardwareProfiles` as `false`:
~~~
oc patch OdhDashboardConfig odh-dashboard-config -n redhat-ods-applications --type=merge --patch='{"spec":{"dashboardConfig":{"disableHardwareProfiles": false}}}'
~~~

When opens the `OdhDashboardConfig` CR, it shouls show:
~~~
...
  spec:
    dashboardConfig:
      disableHardwareProfiles: false
~~~

Open the OpenShift AI console and verify that "Hardware Profile" is visible in the Setting menu (Settings > Hardware profiles):

<img width="230" height="618" alt="hw-profile" src="https://github.com/user-attachments/assets/1bded4e3-cf06-4b73-9d91-774576be6193" />


## Creating a Hardware Profile

### Navigate Settings > Hardware profiles > Add new hardware profile
<img width="1016" height="480" alt="add-new-hw-profile" src="https://github.com/user-attachments/assets/299be9d5-f602-4194-831b-6863746d9d95" />

### Fill the hardware profile form. Important, add "nvidia.com/gpu" as  "Resource identifier"
<img width="731" height="591" alt="fill-hw-form-Edit" src="https://github.com/user-attachments/assets/ff0df440-449b-46ca-9f91-8aaeb58f2b85" />

### Check and edit the configured Memory&GPU resources for the hardware profile
<img width="1035" height="300" alt="hw-profile-resources-summary" src="https://github.com/user-attachments/assets/bf6b3591-b606-4262-a1ec-baef37141ed9" />

### Finish the hardware profile configuration
<img width="1044" height="379" alt="finish-hw-profile" src="https://github.com/user-attachments/assets/838f7450-29e9-4b21-8045-e6717c5fff4f" />
