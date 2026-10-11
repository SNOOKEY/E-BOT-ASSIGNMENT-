> A platform is running around 40 Ingress objects on `ingress-nginx`,
> which has reached end-of-life. You need to migrate to the Kubernetes Gateway
> API with no downtime. Outline your approach, the order you would do things in,
> and what you expect to break along the way.

# Migrating from ingress-nginx to Gateway-API

* Run both stacks in parallel untill migration completes. Gradually shift traffic dns.
* Pick an controller and on our convinence and deploy alongside the ingress-nginx.
* Define sharedgateways and gatwaysClass with restrictions.
* Draft the ingress gateway and translate annotations into policies.
* Start the migration with low-risk services first and move gradually.
* After the complete migration keep the ingress-nginx untill next cycle is done without any issues. And then uninstall them one by one.