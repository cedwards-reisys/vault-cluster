# Jenkins Shared Library Code

Files in this directory are meant to be copied into the `jenkins-shared-lib` repository.

## withAwsAuth

Copy `vars/withAwsAuth.groovy` to `vars/withAwsAuth.groovy` in your shared library.

Before using, update `PROD_ROLE_ARN` with your prod AWS account ID.

### Usage

```groovy
// nonprod - uses instance profile, no credentials needed
withAwsAuth('nonprod-test', img) {
    sh './scripts/cluster-status.sh'
}

// prod - assumes role in prod account automatically
withAwsAuth('prod', img) {
    sh './scripts/cluster-status.sh'
}

// with extra docker args
withAwsAuth('prod', img, '-e VAULT_SKIP_VERIFY=true') {
    sh 'vault status'
}
```
