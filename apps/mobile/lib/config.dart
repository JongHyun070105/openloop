const defaultOpenLoopApiBaseUrl =
    'https://mrodt7pxq4.execute-api.ap-northeast-2.amazonaws.com/dev';

const configuredOpenLoopApiBaseUrl = String.fromEnvironment(
  'OPENLOOP_API_BASE_URL',
  defaultValue: defaultOpenLoopApiBaseUrl,
);
