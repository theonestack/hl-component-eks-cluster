# eks-cluster CfHighlander project

[![Build Status](https://travis-ci.com/theonestack/hl-component-eks-cluster.svg?branch=master)](https://travis-ci.com/theonestack/hl-component-eks-cluster)

## Cfhighlander Setup

install cfhighlander [gem](https://github.com/theonestack/cfhighlander)

```bash
gem install cfhighlander
```

or via docker

```bash
docker pull theonestack/cfhighlander
```

compiling the component

```bash
cfcompile eks-cluster
```

compiling with the vaildate fag to validate the component

```bash
cfcompile eks-cluster --validate
```

test the component

```bash
cfhighlander cftest eks-cluster
```
