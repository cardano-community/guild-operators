
# Docker Security best practice

## Intro

On the security front, Docker developers are faced with different types of security attacks such as:

- Kernel exploits: Since the host’s kernel is shared in the container, a compromised container can attack the entire host.
- Container breakouts: Caused when the user is able to escape the container namespace and interact with other processes on the host.
- Denial-of-service attacks: Occur when some containers take up enough resources to hamper the functioning of other applications.
- Poisoned images: Caused when an untrusted image is being run and a hacker is able to access application data and, potentially, the host itself.

> Docker containers are now being exploited to covertly mine for cryptocurrency, marking a shift from ransomware to cryptocurrency malware. 
As with all things in security, also Docker security is a moving target — so it’s helpful to have access to up-to-date information, including experience-based best practices, for securing your containerized environments.

## Here below some key concepts:

1. Use a Third-Party Security Tool
Docker allows you to use containers from untrusted public repositories, which increases the need to scrutinize whether the container was created securely and whether it is free of any corrupt or malicious files. For this, use a multi-purpose security tool that gives extensive dev-to-production security controls.(keep reading below)

2. Manage Vulnerability
It is best to have a sound vulnerability management program that has multiple checks throughout the container lifecycle. Vulnerability management should incorporate quality gates to detect access issues and weaknesses for a potential exploit from dev-to-production environments.

3. Monitor and Audit Container Activity
It is vital to monitor the container ecosystem and detect suspicious activity. Container monitoring activities provide real-time reports that can help you react promptly to a security breach.

4. Enable Docker Content Trust
[Docker Content Trust](<https://docs.docker.com/engine/security/trust/> )is a new feature incorporated into Docker 1.8. It is disabled by default, but once enabled, allows you to verify the integrity, authenticity, and publication date of all Docker images from the Docker Hub Registry.

5. Use Docker Bench for Security
You should consider [Docker Bench for Security](https://github.com/docker/docker-bench-security) as your must-use script. Once the script is run, you will notice a lot of information regarding configuration best practices for deploying Docker containers that can be used to further secure your Docker server and containers.

6. Resource Utilization
To reduce performance impacts and denial-of-service attacks, it is a good practice to implement limits on the system resources that the containers can consume. If, for example, a web server is compromised, it helps to limit the impact to the other processes that are running on a host.

7. RBAC
RBAC is role-based access control. If you have multiple users accessing you enviroment, this is a must-have. It can be quite expensive to implement but [portainer](https://www.funkypenguin.co.nz/blog/docker-rbac-with-portainer/) makes it super easy.

## Security Docker best practice: 
#### The Guild Docker images are not using all the following tips due to functional purpose

Guild tips:
- **`NEVER NEVER NEVER expose Docker API publicly!!!`** (disabled by default)

- Keep Docker Host Up-to-date
- Reverse uptime: containers that are frequently shut down and replaced by new container are more difficult for hackers to attack.
- Use a Firewall or Expose only the ports you need to be public.
- Use a *`Reverse Proxy`
- Do not Change **`Docker Socket Ownership`
- Do not `Run Docker Containers as Root`
- `Use Trusted Docker Images`
- `Use Privileged Mode Carefully` (This is usually done by adding --privileged you can use `--security-opt=no-new-privileges` instead)

Some more general tips:
- Restrict container capabilities: `"--cap-drop ALL"`
- [Use Docker Secrets](https://www.docker.com/blog/docker-secrets-management/)
- Change DOCKER_OPTS to ***Respect IP Table Firewall 
- [Control Docker Resource Usage](https://docs.docker.com/config/containers/resource_constraints/)
- [Rate Limit](https://docs.docker.com/docker-hub/download-rate-limit/): is quite common to mitigate brute force or denial of service attacks.
- [Fail2ban](https://www.fail2ban.org/wiki/index.php/Main_Page): Fail2ban scans your log files and bans IP address that shows malicious intent
- [Container Vulnerability Scanner](https://github.com/quay/clair)

### Notes:
- *Nginx is a very good choice as load balancer and/or reverse proxy.
- **By default the socket is owned by root user and docker group.
- *** On Ubuntu/Debian based systems, edit /etc/default/docker and add the following line: ```DOCKER_OPTS= "--iptables=false"```