#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { AuroraServerlessStack } from '../lib/aurora_serverless_stack';

const app = new cdk.App();

// Asegúrate de que el nombre del stack coincida con lo que deseas ver en CloudFormation
new AuroraServerlessStack(app, 'QR-Code-AuroraStack', {
  env: { 
    account: '326041476300', 
    region: 'us-east-1' 
  },
});
